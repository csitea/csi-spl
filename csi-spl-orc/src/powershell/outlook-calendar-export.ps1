<#
.SYNOPSIS
  Export the next -Days days of the default Outlook calendar as one
  spool-hub-outlook-export/1 JSON file (spec 180 FR-1).

.DESCRIPTION
  Reads Outlook through COM, read-only (FR-8: nothing is written back). The
  window is today 00:00 local to -Days days later. Recurrences are expanded
  to their occurrences; cancelled meetings are left out. Each event carries
  title, start and end in UTC (RFC 3339), all-day day and end_day (inclusive),
  location, busy status, private, recurring and a source id
  (GlobalAppointmentID@<local start as yyyyMMddTHHmmss>, the form the
  2026-11-17 one-off run wrote). No body and no attendees are read.

  Every date and time in the output is formatted with InvariantCulture: on a
  Finnish-locale box 'HH:mm:ss' with the current culture writes 06.30.00
  (spec 180 section 1.6). Only the Restrict filter uses the box's own date
  format, because that is what Outlook parses.

  The file is imported with do_spl_calendar_import_outlook (csi-spl-orc).

.PARAMETER Days
  How many days from today 00:00 local, 1..60 (default 14).

.PARAMETER OutFile
  The file to write (UTF-8, no BOM), or STDOUT (default) to print the JSON.

.PARAMETER SelfTest
  Convert synthetic items under fi-FI with Windows' '.' time separator and
  check the output;
  Outlook is not opened. Exit 0 when every check holds.

.EXAMPLE
  powershell -NoProfile -File outlook-calendar-export.ps1 -Days 14 -OutFile STDOUT
.EXAMPLE
  pwsh -NoProfile -File outlook-calendar-export.ps1 -SelfTest
#>
param(
  [ValidateRange(1, 60)][int]$Days = 14,
  [string]$OutFile = 'STDOUT',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Format = 'spool-hub-outlook-export/1'
$UtcFmt = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"
$DayFmt = "yyyy'-'MM'-'dd"
$LocalFmt = "yyyyMMdd'T'HHmmss"
# OlBusyStatus 0..5 and OlMeetingStatus 5 / 7 (cancelled), OlSensitivity 2 (private).
$BusyNames = @{ 0 = 'Free'; 1 = 'Tentative'; 2 = 'Busy'; 3 = 'OutOfOffice'; 4 = 'WorkingElsewhere' }
$Cancelled = @(5, 7)

function Format-Utc([datetime]$t) {
  return $t.ToUniversalTime().ToString($UtcFmt, $Inv)
}

# ConvertTo-SpoolEvent: one Outlook occurrence (or a look-alike object) to
# the export's event, or $null for a cancelled meeting.
function ConvertTo-SpoolEvent($it) {
  if ($Cancelled -contains [int]$it.MeetingStatus) { return $null }
  $start = [datetime]$it.Start
  $end = [datetime]$it.End
  $ev = [ordered]@{
    source_id   = [string]$it.GlobalAppointmentID + '@' + $start.ToString($LocalFmt, $Inv)
    title       = [string]$it.Subject
    starts_at   = Format-Utc $start
    ends_at     = Format-Utc $end
    all_day     = [bool]$it.AllDayEvent
    day         = ''
    end_day     = ''
    location    = [string]$it.Location
    busy_status = $BusyNames[[int]$it.BusyStatus]
    private     = ([int]$it.Sensitivity -eq 2)
    recurring   = [bool]$it.IsRecurring
  }
  if ($ev.all_day) {
    $last = $end.Date.AddDays(-1)
    if ($last -lt $start.Date) { $last = $start.Date }
    $ev.day = $start.ToString($DayFmt, $Inv)
    $ev.end_day = $last.ToString($DayFmt, $Inv)
  }
  if ($null -eq $ev.busy_status) { $ev.busy_status = '' }
  return $ev
}

# Get-IanaZone: the box's zone as an IANA id when this .NET can say it,
# else its Windows id (the hub stores such a zone as UTC).
function Get-IanaZone {
  $tz = [TimeZoneInfo]::Local
  $iana = $null
  $m = [TimeZoneInfo].GetMethod('TryConvertWindowsIdToIanaId', [type[]]@([string], [string].MakeByRefType()))
  if ($null -ne $m -and [TimeZoneInfo]::TryConvertWindowsIdToIanaId($tz.Id, [ref]$iana)) { return $iana }
  return $tz.Id
}

function New-Export([datetime]$from, [datetime]$to, $events) {
  return [ordered]@{
    format      = $Format
    exported_at = Format-Utc (Get-Date)
    time_zone   = Get-IanaZone
    from        = Format-Utc $from
    to          = Format-Utc $to
    count       = @($events).Count
    events      = @($events)
  }
}

function Read-OutlookEvents([datetime]$from, [datetime]$to) {
  $ol = New-Object -ComObject Outlook.Application
  $cal = $ol.GetNamespace('MAPI').GetDefaultFolder(9)
  $items = $cal.Items
  $items.Sort('[Start]')
  $items.IncludeRecurrences = $true
  $filter = "[Start] < '" + $to.ToString('g') + "' AND [End] > '" + $from.ToString('g') + "'"
  $out = New-Object System.Collections.ArrayList
  foreach ($it in $items.Restrict($filter)) {
    $ev = ConvertTo-SpoolEvent $it
    if ($null -ne $ev) { [void]$out.Add($ev) }
  }
  return , $out.ToArray()
}

function Invoke-SelfTest {
  # fi-FI as Windows has it (time separator '.'); ICU's fi-FI on Linux has ':'.
  $fi = [Globalization.CultureInfo]::new('fi-FI')
  $fi.DateTimeFormat.TimeSeparator = '.'
  [Threading.Thread]::CurrentThread.CurrentCulture = $fi
  $timed = [pscustomobject]@{ GlobalAppointmentID = 'ABC'; Subject = 'Synthetic'; Start = [datetime]'2027-02-01 06:30:00'
    End = [datetime]'2027-02-01 07:00:00'; AllDayEvent = $false; Location = 'Room 1'; BusyStatus = 2; Sensitivity = 0
    IsRecurring = $true; MeetingStatus = 1 }
  $day = [pscustomobject]@{ GlobalAppointmentID = 'DEF'; Subject = 'All day'; Start = [datetime]'2027-02-03 00:00:00'
    End = [datetime]'2027-02-04 00:00:00'; AllDayEvent = $true; Location = ''; BusyStatus = 3; Sensitivity = 2
    IsRecurring = $false; MeetingStatus = 0 }
  $gone = [pscustomobject]@{ GlobalAppointmentID = 'GHI'; Subject = 'Gone'; Start = [datetime]'2027-02-01 08:00:00'
    End = [datetime]'2027-02-01 09:00:00'; AllDayEvent = $false; Location = ''; BusyStatus = 2; Sensitivity = 0
    IsRecurring = $false; MeetingStatus = 5 }
  $a = ConvertTo-SpoolEvent $timed
  $b = ConvertTo-SpoolEvent $day
  $rfc = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
  $checks = [ordered]@{
    'timed starts_at is RFC 3339' = ($a.starts_at -match $rfc)
    'timed ends_at is RFC 3339'   = ($a.ends_at -match $rfc)
    'source_id is id@local start' = ($a.source_id -eq 'ABC@20270201T063000')
    'all-day day and end_day'     = ($b.day -eq '2027-02-03' -and $b.end_day -eq '2027-02-03')
    'busy status and private'     = ($a.busy_status -eq 'Busy' -and $b.busy_status -eq 'OutOfOffice' -and $b.private)
    'a cancelled meeting is out'  = ($null -eq (ConvertTo-SpoolEvent $gone))
    'one event stays an array'    = ((New-Export (Get-Date) (Get-Date) @($a) | ConvertTo-Json -Depth 4 -Compress) -match '"events":\[\{')
  }
  $bad = 0
  foreach ($k in $checks.Keys) {
    if ($checks[$k]) { Write-Output "PASS $k" } else { Write-Output "FAIL $k"; $bad++ }
  }
  exit $(if ($bad -eq 0) { 0 } else { 1 })
}

if ($SelfTest) { Invoke-SelfTest }
$from = (Get-Date).Date
$to = $from.AddDays($Days)
$json = New-Export $from $to (Read-OutlookEvents $from $to) | ConvertTo-Json -Depth 4 -Compress
if ($OutFile -eq 'STDOUT') {
  [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
  Write-Output $json
} else {
  [IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding $false))
}
