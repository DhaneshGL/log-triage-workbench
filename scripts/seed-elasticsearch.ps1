[CmdletBinding()]
param(
    [string]$ElasticsearchUrl = "http://localhost:9200",
    [string]$KibanaUrl = "http://localhost:5601"
)

$ErrorActionPreference = "Stop"

$dataPath = Join-Path $PSScriptRoot "..\data\application.jsonl"
$samples = @(
    Get-Content -LiteralPath $dataPath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ | ConvertFrom-Json }
)

if ($samples.Count -eq 0) {
    throw "No sample events found in $dataPath."
}

$sampleTimes = @(
    $samples | ForEach-Object {
        [DateTimeOffset]::Parse($_.timestamp).ToUniversalTime()
    }
)
$lastSampleTime = ($sampleTimes | Measure-Object -Maximum).Maximum
# Keep the sample within a recent Kibana time window while allowing for clock drift.
$now = [DateTimeOffset]::UtcNow.AddMinutes(-10)
$indexName = "portfolio-app-logs-$($now.ToString('yyyy.MM.dd'))"

$indexUrl = "$($ElasticsearchUrl.TrimEnd('/'))/$indexName"
$indexExists = $false
try {
    $null = Invoke-RestMethod -Uri $indexUrl -Method Get
    $indexExists = $true
}
catch {
    $statusCode = 0
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -ne 404) {
        throw
    }
}

if (-not $indexExists) {
    $mapping = @{
        mappings = @{
            properties = @{
                timestamp     = @{ type = "date" }
                level         = @{ type = "keyword" }
                service       = @{ type = "keyword" }
                host          = @{ type = "keyword" }
                correlation_id = @{ type = "keyword" }
                message       = @{ type = "text" }
                duration_ms   = @{ type = "integer" }
            }
        }
    } | ConvertTo-Json -Depth 8
    $null = Invoke-RestMethod -Uri $indexUrl -Method Put -ContentType "application/json" -Body $mapping
}

$bulkLines = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $samples.Count; $i++) {
    $eventTime = $sampleTimes[$i]
    $event = $samples[$i]
    $event.timestamp = $now.Add($eventTime - $lastSampleTime).ToString("o")

    $bulkLines.Add(
        (@{ index = @{ _index = $indexName; _id = ("sample-{0:d3}" -f ($i + 1)) } } |
            ConvertTo-Json -Compress)
    )
    $bulkLines.Add(($event | ConvertTo-Json -Compress))
}

$bulkBody = ($bulkLines -join "`n") + "`n"
$bulkResult = Invoke-RestMethod `
    -Uri "$($ElasticsearchUrl.TrimEnd('/'))/_bulk" `
    -Method Post `
    -ContentType "application/x-ndjson" `
    -Body $bulkBody

if ($bulkResult.errors) {
    $failures = $bulkResult.items |
        Where-Object { $_.index.error } |
        ForEach-Object { $_.index.error | ConvertTo-Json -Compress -Depth 5 }
    throw "Elasticsearch rejected sample log documents: $($failures -join '; ')"
}

$null = Invoke-RestMethod -Uri "$indexUrl/_refresh" -Method Post

$headers = @{ "kbn-xsrf" = "true" }
$dataViewsUrl = "$($KibanaUrl.TrimEnd('/'))/api/data_views"
$dataViews = Invoke-RestMethod -Uri $dataViewsUrl -Headers $headers
$dataView = $dataViews.data_view | Where-Object { $_.title -eq "portfolio-app-logs-*" } | Select-Object -First 1

if (-not $dataView) {
    $dataViewBody = @{
        data_view = @{
            title        = "portfolio-app-logs-*"
            name         = "Application Support Demo Logs"
            timeFieldName = "timestamp"
        }
    } | ConvertTo-Json -Depth 4
    $dataView = Invoke-RestMethod `
        -Uri "$dataViewsUrl/data_view" `
        -Method Post `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $dataViewBody
}

Write-Output "Indexed $($samples.Count) sample events in $indexName."
Write-Output "Kibana data view: Application Support Demo Logs (portfolio-app-logs-*)"
Write-Output "Discover URL: $($KibanaUrl.TrimEnd('/'))/app/discover"
