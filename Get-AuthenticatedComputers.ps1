<#
.SYNOPSIS
     This script parses the 'Security' event log for radius authentication requests and matches the computer
     to it's owner and connection type, wired or wireless.
.DESCRIPTION
    This script captures one day of radius authention and emails the created CSV report to the business team for data processing.
.NOTES
    Version:        2.0
    Author:         Devon Jobes
    Creation Date:  01/25/2019
    Purpose/Change: Fixed processing logic.
#>


Try
{
    # | --------------------------------------------------------------------
    # |                             Initial Prep
    # | --------------------------------------------------------------------

    # | Get the parent directory of the script on the filesystem and change
    # | the current working directory of the script to that location.
    Set-Location $PSScriptRoot

    # | Import the Write-ScriptLog Module to create logs.
    . "$PSScriptRoot\Location\Of\Function\Write-ScriptLog.ps1"

    # | Capture the user and host that ran the script along with date/time
    # | info for timestamping

    $Username = $ENV:USERNAME
    $Hostname = $ENV:COMPUTERNAME
    $Time = Get-Date -f HH:mm:ss
    $Date = Get-Date -f yyyy-MM-dd

    # | *********************** BEGIN PROGRAM BELOW ************************ | #

    # | Create credential file for script authentication.
    $PSSWD = Get-Content "STRING.txt" | ConvertTo-SecureString
    $STRING = New-Object System.Management.Automation.PSCredential "username",$PSSWD

    # | Array of server names to parse security logs.
    $officeDC=@("server-01.domain.dom","server-02.domain.dom", "server-03.domain.dom")

    # | Pull logs, create objects, populate objects with data and email CSV
    foreach($server in $officeDC)
        {
            # | Create session to remote server
            $logSession = New-PSSession -ComputerName $server -Credential $STRING -ErrorAction Continue
            # | Create log object
            Invoke-Command -Session $logSession -ScriptBlock {
            # | Empty computer array
            $authenticatedComps=@()
            # | Set Location of script
            $currentLocation = (Get-Location).ToString()
            # | Switch server name to something easily readable
            $server = $ENV:COMPUTERNAME
            $serverNameSwitched = ""
            switch($server)
                {
                    "server-01"{$serverNameSwitched = "Server 01"}
                    "server-02"{$serverNameSwitched = "Server 02"}
                    "server-03"{$serverNameSwitched = "Server 03"}
                }
            
            # | Time for filename
            $fileNameTime = Get-Date -f 'yyyyMMddTHHmmss'
            # | Time for email
            $emailDate = Get-Date -F 'MM/dd/yyyy'
            # | Filename for report
            $fileName = $serverNameSwitched + "_" + $fileNameTime + ".csv"
            # | Delete previous CSV
            $previousCSV = Get-ChildItem $currentLocation | Where-Object {$_ -like "*.csv"}
            if($previousCSV)
                {
                    Remove-Item $previousCSV -Force
                }
            # | Create a new CSV
            New-Item -ItemType file -Path $currentLocation -Force -Name $fileName
            # | CSV location
            $csvLocation = $currentLocation + "\" + $fileName
            # | Create time variables
            $midnightCurrentDay = Get-Date -Hour 0 -Minute 00 -Second 00
            $currentTime = Get-Date -Hour 23 -Minute 59 -Second 00
            # | Get local log for each time zone
            if($server -eq "server-01" -or $server -eq "server-02")
                {
                    $securityLog=Get-EventLog -LogName 'Security' -InstanceId '6278' -After ($midnightCurrentDay).AddDays(-1) -Before ($currentTime).AddDays(-1)
                }
            else
                {
                    $securityLog=Get-EventLog -LogName 'Security' -InstanceId '6278' -After $midnightCurrentDay -Before $currentTime
                }
            # | Parse logs and build data objects
            if(!$securityLog)
                {
                    $logErrorSubject = "Having issues parsing log for: " + $server
                    $logErrorMessage = $server + ": issues parsing logs for " + $emailDate + "."
                    $logErrorRecipient = "recipient01@domain.com"
                    Send-MailMessage -To $logErrorRecipient -From "sender@openx.com" -Subject $logErrorSubject -Body $logErrorMessage -SmtpServer 'mail-server.domain.com' -port '25' -DeliveryNotificationOption None
                    Continue
                }
            else
                {
                    foreach($log in $securityLog)
                        {
                            # | Empty variables
                            $computerName = ""
                            $managedBy = ""
                            # | Log fields
                            $accountName = ($log.ReplacementStrings[1].Replace("@",'').Replace("/",'').Replace("$",'').Replace("host",'').Replace(".",'').Replace("domaincom",'')).ToString()
                            $macAddress = $log.ReplacementStrings[9].Replace("-",'').ToUpper()
                            $connectedTo = $log.ReplacementStrings[15]
                            $connectionType = $log.ReplacementStrings[13].Replace(" - IEEE 802.11",'')
                            $vlanPolicy = $log.ReplacementStrings[18]
                            $connectionTime = ($log.TimeGenerated).ToString()
                            # | Skip over non-computer Radius requests
                            if($accountName -like "rancid" -or $accountName -like "-")
                                {
                                    Continue
                                }
                            elseif(!$accountName)
                                {
                                    Continue
                                }
                            else
                                {
                                    $computerObject = Get-ADComputer -LDAPFilter "(&(name=$accountName)(ObjectClass=computer))" -Properties ManagedBy -Credential $Using:STRING -ErrorAction Continue
                                    if($computerObject)
                                        {
                                            if($computerObject.Name)
                                                {
                                                    $computerName += $computerObject.Name
                                                }
                                            else
                                                {
                                                    $computerName = "Computer name is not listed for connection."
                                                }
                                            if($computerObject.ManagedBy)
                                                {
                                                    $managedBy += $computerObject.ManagedBy.Split('=').Split(',')[1]
                                                }
                                            else
                                                {
                                                    $managedBy = "No associated user account listed for computer."
                                                }
                                        }
                                            
                                }
                            # | Build report data
                            $logRebuilt = New-Object System.Object
                            $logRebuilt | Add-Member -MemberType NoteProperty -Name UserAccount -Value $managedBy
                            $logRebuilt | Add-Member -MemberType NoteProperty -Name ComputerName -Value $computerName
                            $logRebuilt | Add-Member -MemberType NoteProperty -Name MachineAddressCode -Value $macAddress
                            $logRebuilt | Add-Member -MemberType NoteProperty -Name ConnectionTime -Value $connectionTime
                            $logRebuilt | Add-Member -MemberType NoteProperty -Name ConnectedTo -Value $connectedTo
                            $logRebuilt | Add-Member -MemberType NoteProperty -Name ConnectionType -Value $connectionType
                            $logRebuilt | Add-Member -MemberType NoteProperty -Name VLANConnection -Value $vlanPolicy
                            $authenticatedComps += $logRebuilt
                        }
                
                }
            # | Email CSV
            if(!$authenticatedComps)
                {
                    $emailRecipients = @("recipient01@domain.com")
                    $emailSubject = $serverNameSwitched + ": zero computers authenticated on the network " + $emailDate + "."
                    Send-MailMessage -To $emailRecipients -From "sender@domain.com" -Subject $emailSubject -Body $emailSubject -SmtpServer 'mail-server.domain.com' -port '25' -DeliveryNotificationOption None
                }
            else
                {
                    $emailRecipients = @("recipient02@openx.com","recipient03@domain.com")
                    $authenticatedComps | Export-Csv -Path $csvLocation -Force -NoTypeInformation
                    $emailSubject = $serverNameSwitched + ": authenticated computers report " + $emailDate + "."
                    Send-MailMessage -To $emailRecipients -From "custom-report@openx.com" -Subject $emailSubject -Attachments $csvLocation -Body "All authenticated computers on the network report attached." -SmtpServer 'mail-server.domain.com' -port '25' -DeliveryNotificationOption None
                }

            # | Time to catch up
            Start-Sleep -Second 5
            # | Delete current working CSV file
            if($csvLocation)
                {
                    Remove-Item $csvLocation -Force
                }
        }
    }

        
}
Catch
{
    # | Capture not only the error message itself but also the line of the
    # | script it occurred on and the column (character) of that line.

    $Message = $_.Exception.Message
    $Line = $_.InvocationInfo.ScriptLineNumber
    $Column = $_.InvocationInfo.OffsetInLine

    $Source = $MyInvocation.MyCommand.Name + ".ps1"
    $Logfilename = $MyInvocation.MyCommand.Name
    $LogFile = "C:\Location\Of\Logs\" + $Logfilename + ".txt"
    
    Write-ScriptLog -Message $Message -Type "ERROR" -File $LogFile `
    -Date $Date -Time $Time -Source $Source -Line $Line `
    -Column $Column -SourceHost $Hostname -User $Username

    Write-Host -F Red $Message
}
