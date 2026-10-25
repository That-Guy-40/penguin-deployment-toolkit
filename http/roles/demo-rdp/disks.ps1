# disks.ps1 - what this Windows sees: disks, volumes, and any PDT-MARKER.txt
# (bin/smoke puts one on the removable media it attaches). Output is read by
# post.cmd and uploaded as disks.txt.
Get-Disk | Sort-Object Number | ForEach-Object {
    'disk {0}|{1}|{2}|{3}GB|{4}' -f $_.Number, ($_.FriendlyName -replace '\s+', ' ').Trim(), $_.BusType, [math]::Round($_.Size / 1GB), $_.PartitionStyle
}
Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter | ForEach-Object {
    'vol {0}: {1} {2}GB label={3}' -f $_.DriveLetter, $_.FileSystemType, [math]::Round($_.Size / 1GB), $_.FileSystemLabel
    $m = '{0}:\PDT-MARKER.txt' -f $_.DriveLetter
    if (Test-Path -LiteralPath $m) { 'marker {0}: {1}' -f $_.DriveLetter, (Get-Content -LiteralPath $m -Raw).Trim() }
}
