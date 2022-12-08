<#

.SYNOPSIS
    Resets Hybrid AzureAD join connection.

.DESCRIPTION
    
    Script will:
     - un-join computer from AzureAD (using dsregcmd.exe)
     - remove leftover certificates
     - invoke rejoin (using sched. task 'Automatic-Device-Join')
     - Loop and wait up to 30 minutes to confirm AzureAD connection.
     - inform user about the result


    Original script from Ondrej Sebela (tw:@AndrewZtrhgf), described in the following blog:
    https://doitpsway.com/fixing-hybrid-azure-ad-join-on-a-device-using-powershell

    Modified to wait up to 30 minutos for device connection to be confirmed.
    Original script at: https://github.com/ztrhgf/useful_powershell_functions/blob/master/INTUNE/Reset-HybridADJoin.ps1

    
.NOTES

#>
function Reset-HybridADJoin {
    <#
    .SYNOPSIS
    Function for resetting Hybrid AzureAD join connection.

    .DESCRIPTION
    Function for resetting Hybrid AzureAD join connection.
    It will:
     - un-join computer from AzureAD (using dsregcmd.exe)
     - remove leftover certificates
     - invoke rejoin (using sched. task 'Automatic-Device-Join')
     - inform user about the result

    .PARAMETER computerName
    (optional) name of the computer you want to rejoin.

    .EXAMPLE
    Reset-HybridADJoin

    Un-join and re-join this computer to AzureAD

    .NOTES
    Source: https://www.maximerastello.com/manually-re-register-a-windows-10-or-windows-server-machine-in-hybrid-azure-ad-join/
    #>

    [CmdletBinding()]
    param (
        [string] $computerName
    )

    Write-Warning "For join AzureAD process to work. Computer account has to exists in AzureAD already (should be synchronized via 'AzureAD Connect')!"

    #region helper functions
    function Invoke-AsSystem {
        <#
        .SYNOPSIS
        Function for running specified code under SYSTEM account.

        .DESCRIPTION
        Function for running specified code under SYSTEM account.

        Helper files and sched. tasks are automatically deleted.

        .PARAMETER scriptBlock
        Scriptblock that should be run under SYSTEM account.

        .PARAMETER computerName
        Name of computer, where to run this.

        .PARAMETER returnTranscript
        Add creating of transcript to specified scriptBlock and returns its output.

        .PARAMETER cacheToDisk
        Necessity for long scriptBlocks. Content will be saved to disk and run from there.

        .PARAMETER argument
        If you need to pass some variables to the scriptBlock.
        Hashtable where keys will be names of variables and values will be, well values :)

        Example:
        [hashtable]$Argument = @{
            name = "John"
            cities = "Boston", "Prague"
            hash = @{var1 = 'value1','value11'; var2 = @{ key ='value' }}
        }

        Will in beginning of the scriptBlock define variables:
        $name = 'John'
        $cities = 'Boston', 'Prague'
        $hash = @{var1 = 'value1','value11'; var2 = @{ key ='value' }

        ! ONLY STRING, ARRAY and HASHTABLE variables are supported !

        .PARAMETER runAs
        Let you change if scriptBlock should be running under SYSTEM, LOCALSERVICE or NETWORKSERVICE account.

        Default is SYSTEM.

        .EXAMPLE
        Invoke-AsSystem {New-Item $env:TEMP\abc}

        On local computer will call given scriptblock under SYSTEM account.

        .EXAMPLE
        Invoke-AsSystem {New-Item "$env:TEMP\$name"} -computerName PC-01 -ReturnTranscript -Argument @{name = 'someFolder'} -Verbose

        On computer PC-01 will call given scriptblock under SYSTEM account i.e. will create folder 'someFolder' in C:\Windows\Temp.
        Transcript will be outputted in console too.
        #>

        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [scriptblock] $scriptBlock,

            [string] $computerName,

            [switch] $returnTranscript,

            [hashtable] $argument,

            [ValidateSet('SYSTEM', 'NETWORKSERVICE', 'LOCALSERVICE')]
            [string] $runAs = "SYSTEM",

            [switch] $CacheToDisk
        )

        (Get-Variable runAs).Attributes.Clear()
        $runAs = "NT Authority\$runAs"

        #region prepare Invoke-Command parameters
        # export this function to remote session (so I am not dependant whether it exists there or not)
        $allFunctionDefs = "function Create-VariableTextDefinition { ${function:Create-VariableTextDefinition} }"

        $param = @{
            argumentList = $scriptBlock, $runAs, $CacheToDisk, $allFunctionDefs, $VerbosePreference, $ReturnTranscript, $Argument
        }

        if ($computerName -and $computerName -notmatch "localhost|$env:COMPUTERNAME") {
            $param.computerName = $computerName
        } else {
            if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
                throw "You don't have administrator rights"
            }
        }
        #endregion prepare Invoke-Command parameters

        Invoke-Command @param -ScriptBlock {
            param ($scriptBlock, $runAs, $CacheToDisk, $allFunctionDefs, $VerbosePreference, $ReturnTranscript, $Argument)

            foreach ($functionDef in $allFunctionDefs) {
                . ([ScriptBlock]::Create($functionDef))
            }

            $TranscriptPath = "$ENV:TEMP\Invoke-AsSYSTEM_$(Get-Random).log"

            if ($Argument -or $ReturnTranscript) {
                # define passed variables
                if ($Argument) {
                    # convert hash to variables text definition
                    $VariableTextDef = Create-VariableTextDefinition $Argument
                }

                if ($ReturnTranscript) {
                    # modify scriptBlock to contain creation of transcript
                    $TranscriptStart = "Start-Transcript $TranscriptPath"
                    $TranscriptEnd = 'Stop-Transcript'
                }

                $ScriptBlockContent = ($TranscriptStart + "`n`n" + $VariableTextDef + "`n`n" + $ScriptBlock.ToString() + "`n`n" + $TranscriptStop)
                Write-Verbose "####### SCRIPTBLOCK TO RUN"
                Write-Verbose $ScriptBlockContent
                Write-Verbose "#######"
                $scriptBlock = [Scriptblock]::Create($ScriptBlockContent)
            }

            if ($CacheToDisk) {
                $ScriptGuid = New-Guid
                $null = New-Item "$($ENV:TEMP)\$($ScriptGuid).ps1" -Value $ScriptBlock -Force
                $pwshcommand = "-ExecutionPolicy Bypass -Window Hidden -noprofile -file `"$($ENV:TEMP)\$($ScriptGuid).ps1`""
            } else {
                $encodedcommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptBlock))
                $pwshcommand = "-ExecutionPolicy Bypass -Window Hidden -noprofile -EncodedCommand $($encodedcommand)"
            }

            $OSLevel = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentVersion
            if ($OSLevel -lt 6.2) { $MaxLength = 8190 } else { $MaxLength = 32767 }
            if ($encodedcommand.length -gt $MaxLength -and $CacheToDisk -eq $false) {
                throw "The encoded script is longer than the command line parameter limit. Please execute the script with the -CacheToDisk option."
            }

            try {
                #region create&run sched. task
                $A = New-ScheduledTaskAction -Execute "$($ENV:windir)\system32\WindowsPowerShell\v1.0\powershell.exe" -Argument $pwshcommand
                if ($runAs -match "\$") {
                    # pod gMSA uctem
                    $P = New-ScheduledTaskPrincipal -UserId $runAs -LogonType Password
                } else {
                    # pod systemovym uctem
                    $P = New-ScheduledTaskPrincipal -UserId $runAs -LogonType ServiceAccount
                }
                $S = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd
                $taskName = "RunAsSystem_" + (Get-Random)
                try {
                    $null = New-ScheduledTask -Action $A -Principal $P -Settings $S -ea Stop | Register-ScheduledTask -Force -TaskName $taskName -ea Stop
                } catch {
                    if ($_ -match "No mapping between account names and security IDs was done") {
                        throw "Account $runAs doesn't exist or cannot be used on $env:COMPUTERNAME"
                    } else {
                        throw "Unable to create helper scheduled task. Error was:`n$_"
                    }
                }

                # run scheduled task
                Start-Sleep -Milliseconds 200
                Start-ScheduledTask $taskName

                # wait for sched. task to end
                Write-Verbose "waiting on sched. task end ..."
                $i = 0
                while (((Get-ScheduledTask $taskName -ErrorAction silentlyContinue).state -ne "Ready") -and $i -lt 500) {
                    ++$i
                    Start-Sleep -Milliseconds 200
                }

                # get sched. task result code
                $result = (Get-ScheduledTaskInfo $taskName).LastTaskResult

                # read & delete transcript
                if ($ReturnTranscript) {
                    # return just interesting part of transcript
                    if (Test-Path $TranscriptPath) {
                        $transcriptContent = (Get-Content $TranscriptPath -Raw) -Split [regex]::escape('**********************')
                        # return command output
                        ($transcriptContent[2] -split "`n" | Select-Object -Skip 2 | Select-Object -SkipLast 3) -join "`n"

                        Remove-Item $TranscriptPath -Force
                    } else {
                        Write-Warning "There is no transcript, command probably failed!"
                    }
                }

                if ($CacheToDisk) { $null = Remove-Item "$($ENV:TEMP)\$($ScriptGuid).ps1" -Force }

                try {
                    Unregister-ScheduledTask $taskName -Confirm:$false -ea Stop
                } catch {
                    throw "Unable to unregister sched. task $taskName. Please remove it manually"
                }

                if ($result -ne 0) {
                    throw "Command wasn't successfully ended ($result)"
                }
                #endregion create&run sched. task
            } catch {
                throw $_.Exception
            }
        }
    }
    #endregion helper functions

    $allFunctionDefs = "function Invoke-AsSystem { ${function:Invoke-AsSystem} }"

    $param = @{
        scriptblock  = {
            param( $allFunctionDefs )

            $ErrorActionPreference = "Stop"

            foreach ($functionDef in $allFunctionDefs) {
                . ([ScriptBlock]::Create($functionDef))
            }

            $dsreg = dsregcmd.exe /status
            if (($dsreg | Select-String "DomainJoined :") -match "NO") {
                throw "Computer is NOT domain joined"
            }

            "Un-joining $env:COMPUTERNAME from Azure"
            Write-Verbose "by running: Invoke-AsSystem { dsregcmd.exe /leave /debug } -returnTranscript"
            Invoke-AsSystem { dsregcmd.exe /leave /debug } #-returnTranscript

            Start-Sleep -Seconds 5
            Get-ChildItem 'Cert:\LocalMachine\My\' | ? { $_.Issuer -match "MS-Organization-Access|MS-Organization-P2P-Access \[\d+\]" } | % {
                Write-Host "Removing leftover Hybrid-Join certificate $($_.DnsNameList.Unicode)" -ForegroundColor Cyan
                Remove-Item $_.PSPath
            }

            $dsreg = dsregcmd.exe /status
            if (!(($dsreg | Select-String "AzureAdJoined :") -match "NO")) {
                throw "$env:COMPUTERNAME is still joined to Azure. Run again"
            }

            # join computer to Azure again
            Write-Host "Joining $env:COMPUTERNAME to Azure"
            Write-Verbose "by running: Get-ScheduledTask -TaskName Automatic-Device-Join | Start-ScheduledTask"
            
            #record Azure AD Join start time. Will fail after trying for 30 minutes.
            $haadjStart = Get-Date
            
            while (($dsreg | Select-String "AzureAdJoined :") -match "NO") {

                Get-ScheduledTask -TaskName "Automatic-Device-Join" | Start-ScheduledTask
                Start-Sleep -Seconds 3

                while ((Get-ScheduledTask "Automatic-Device-Join" -ErrorAction silentlyContinue).state -ne "Ready") {
                    Start-Sleep -Seconds 5
                    Write-Host "Waiting for sched. task 'Automatic-Device-Join' to complete"
                }
                
                Write-Host "`t...Verifying sched. task result"
                Start-Sleep -Seconds 5
                $haadjEnd = Get-Date
                $haadjDiff= New-TimeSpan -Start $haadjStart -End $haadjEnd

                if ((Get-ScheduledTask -TaskName "Automatic-Device-Join" | Get-ScheduledTaskInfo | select -exp LastTaskResult) -ne 0) {

                    #If we've been waiting more than 30 minutes throw error.
                    if ($haadjDiff.Minutes -gt 30) {
                        throw "Sched. task Automatic-Device-Join failed. Is $env:COMPUTERNAME synchronized to AzureAD?"
                    }
                    Write-Host "Error in sched. task, will try again in 30 seconds"
                    if ($haadjDiff -gt 1) { Write-Host "Total elapsed Time = $($haadjDiff.Minutes) minute(s)" }
                    Start-Sleep -Seconds 30
                   
                }

                $dsreg = dsregcmd.exe /status
                
            }


            Write-Host "Device $env:COMPUTERNAME is now Hybrid Azure AD Joined."

            # check certificates
            Write-Host "Waiting for certificate creation"
            $i = 30
            Write-Verbose "two certificates should be created in Computer Personal cert. store (issuer: MS-Organization-Access, MS-Organization-P2P-Access [$(Get-Date -Format yyyy)]"

            Start-Sleep 3

            while (!($hybridJoinCert = Get-ChildItem 'Cert:\LocalMachine\My\' | ? { $_.Issuer -match "MS-Organization-Access|MS-Organization-P2P-Access \[\d+\]" }) -and $i -gt 0) {
                Start-Sleep 5
                --$i
                $i
            }

            # check AzureAd join status
            $dsreg = dsregcmd.exe /status
            if (($dsreg | Select-String "AzureAdJoined :") -match "YES") {
                ++$AzureAdJoined
            }

            if ($hybridJoinCert -and $AzureAdJoined) {
                "$env:COMPUTERNAME was successfully joined to AAD again."
            } else {
                $problem = @()

                if (!$AzureAdJoined) {
                    $problem += " - computer is not AzureAD joined"
                }

                if (!$hybridJoinCert) {
                    $problem += " - certificates weren't created"
                }

                Write-Error "Join wasn't successful:`n$($problem -join "`n")"
                Write-Warning "Check if device $env:COMPUTERNAME exists in AAD"
                Write-Warning "Run:`ngpupdate /force /target:computer"
                Write-Warning "You can get failure reason via manual join by running: Invoke-AsSystem -scriptBlock {dsregcmd /join /debug} -returnTranscript"
                throw 1
            }
        }
        argumentList = $allFunctionDefs
    }

    if ($computerName -and $computerName -notin "localhost", $env:COMPUTERNAME) {
        $param.computerName = $computerName
    } else {
        if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
            throw "You don't have administrator rights"
        }
    }

    Invoke-Command @param
}

Reset-HybridADJoin