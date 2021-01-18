function Invoke-PowerExec {
<#
.SYNOPSIS
    Invoke PowerShell commands on remote computers.

    Author: Timothee MENOCHET (@_tmenochet)

.DESCRIPTION
    Invoke-PowerExec runs PowerShell script block on remote computers through various methods.
    Multi-threading part is mostly stolen from PowerView by @harmj0y and @mattifestation.

.PARAMETER ScriptBlock
    Specifies the PowerShell script block to run.

.PARAMETER ComputerList
    Specifies the target hosts, such as specific addresses or network ranges (CIDR).

.PARAMETER DomainComputers
    Specifies an Active Directory domain for enumerating target hosts.

.PARAMETER Credential
    Specifies the privileged account to use.

.PARAMETER Method
    Specifies the execution method to use, defaults to WMI.

.PARAMETER Threads
    Specifies the number of threads to use, defaults to 5.

.EXAMPLE
    PS C:\> Invoke-PowerExec -ScriptBlock {Write-Output "$Env:COMPUTERNAME ($Env:USERDOMAIN\$Env:USERNAME)"} -ComputerList $(gc hosts.txt)

.EXAMPLE
    PS C:\> New-PowerLoader -FilePath .\script.ps1 | Invoke-PowerExec -DomainComputers ADATUM.CORP -Credential ADATUM\Administrator -Method WinRM -Threads 10
#>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True, ValueFromPipelineByPropertyName = $True)]
        [ScriptBlock]
        $ScriptBlock,

        [ValidateNotNullOrEmpty()]
        [string[]]
        $ComputerList,

        [ValidateNotNullOrEmpty()]
        [string]
        $DomainComputers,

        [ValidateNotNullOrEmpty()]
        [Management.Automation.PSCredential]
        [Management.Automation.Credential()]
        $Credential = [Management.Automation.PSCredential]::Empty,

        [ValidateSet('SchTask', 'WinRM', 'WMI')]
        [String]
        $Method = 'WMI',

        [ValidateNotNullOrEmpty()]
        [Int]
        $Threads = 5
    )

    $hostList = New-Object Collections.ArrayList

    foreach ($computer in $ComputerList) {
        if ($computer.contains("/")) {
            $hostList.AddRange($(New-IPv4RangeFromCIDR -CIDR $computer))
        }
        else {
            $hostList.Add($computer) | Out-Null
        }
    }

    if ($DomainComputers) {
        $searchString = "LDAP://$DomainComputers/RootDSE"
        $domainObject = New-Object DirectoryServices.DirectoryEntry($searchString, $null, $null)
        $rootDN = $domainObject.rootDomainNamingContext[0]
        $ADSpath = "LDAP://$DomainComputers/$rootDN"
        $filter = "(&(samAccountType=805306369)(!userAccountControl:1.2.840.113556.1.4.803:=2))"
        $computers = Get-LdapObject -ADSpath $ADSpath -Filter $filter -Properties 'dnshostname' -Credential $Credential
        foreach ($computer in $computers) {
            if ($computer.dnshostname) {
                $hostList.Add($($computer.dnshostname).ToString()) | Out-Null
            }
        }
    }

    if ($Threads -eq 1 -or $hostList.Count -eq 1) {
        foreach ($computer in $hostList) {
            New-PowerExec -ScriptBlock $ScriptBlock -ComputerName $computer -Credential $Credential -Method $Method
        }
    }
    else {
        $parameters = @{
            ScriptBlock = $ScriptBlock
            Credential = $Credential
            Method = $Method
            Verbose = $VerbosePreference
        }
        New-ThreadedFunction -ScriptBlock ${function:New-PowerExec} -ScriptParameters $parameters -Collection $hostList -CollectionParameter 'ComputerName' -Threads $Threads
    }
}

# Adapted from Find-Fruit by @rvrsh3ll
function Local:New-IPv4RangeFromCIDR {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $CIDR
    )

    $hostList = New-Object Collections.ArrayList
    $netPart = $CIDR.split("/")[0]
    [uint32]$maskPart = $CIDR.split("/")[1]

    $address = [Net.IPAddress]::Parse($netPart)
    if ($maskPart -ge $address.GetAddressBytes().Length * 8) {
        throw "Bad host mask"
    }

    $numhosts = [Math]::Pow(2, (($address.GetAddressBytes().Length * 8) - $maskPart))

    $startaddress = $address.GetAddressBytes()
    [array]::Reverse($startaddress)

    $startaddress = [BitConverter]::ToUInt32($startaddress, 0)
    [uint32]$startMask = ([Math]::Pow(2, $maskPart) - 1) * ([Math]::Pow(2, (32 - $maskPart)))
    $startAddress = $startAddress -band $startMask
    # In powershell 2.0 there are 4 0 bytes padded, so the [0..3] is necessary
    $startAddress = [BitConverter]::GetBytes($startaddress)[0..3]
    [array]::Reverse($startaddress)
    $address = [Net.IPAddress][byte[]]$startAddress

    for ($i = 0; $i -lt $numhosts - 2; $i++) {
        $nextAddress = $address.GetAddressBytes()
        [array]::Reverse($nextAddress)
        $nextAddress = [BitConverter]::ToUInt32($nextAddress, 0)
        $nextAddress++
        $nextAddress = [BitConverter]::GetBytes($nextAddress)[0..3]
        [array]::Reverse($nextAddress)
        $address = [Net.IPAddress][byte[]]$nextAddress
        $hostList.Add($address.IPAddressToString) | Out-Null
    }
    return $hostList
}

function Local:Get-LdapObject {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $ADSpath,

        [ValidateNotNullOrEmpty()]
        [String]
        $SearchScope = 'Subtree',

        [ValidateNotNullOrEmpty()]
        [String]
        $Filter = '(objectClass=*)',

        [ValidateNotNullOrEmpty()]
        [String[]]
        $Properties = '*',

        [ValidateRange(1,10000)] 
        [Int]
        $PageSize = 200,

        [ValidateNotNullOrEmpty()]
        [Management.Automation.PSCredential]
        [Management.Automation.Credential()]
        $Credential = [Management.Automation.PSCredential]::Empty
    )

    if ($Credential.UserName) {
        $domainObject = New-Object DirectoryServices.DirectoryEntry($ADSpath, $Credential.UserName, $Credential.GetNetworkCredential().Password)
        $searcher = New-Object DirectoryServices.DirectorySearcher($domainObject)
    }
    else {
        $searcher = New-Object DirectoryServices.DirectorySearcher([ADSI]$ADSpath)
    }
    $searcher.SearchScope = $SearchScope
    $searcher.PageSize = $PageSize
    $searcher.CacheResults = $false
    $searcher.filter = $Filter
    $propertiesToLoad = $Properties | ForEach-Object {$_.Split(',')}
    $searcher.PropertiesToLoad.AddRange($propertiesToLoad) | Out-Null
    try {
        $results = $searcher.FindAll()
        $results | Where-Object {$_} | ForEach-Object {
            $objectProperties = @{}
            $p = $_.Properties
            $p.PropertyNames | ForEach-Object {
                if (($_ -ne 'adspath') -And ($p[$_].count -eq 1)) {
                    $objectProperties[$_] = $p[$_][0]
                }
                elseif ($_ -ne 'adspath') {
                    $objectProperties[$_] = $p[$_]
                }
            }
            New-Object -TypeName PSObject -Property ($objectProperties)
        }
        $results.dispose()
        $searcher.dispose()
    }
    catch {
        Write-Error $_ -ErrorAction Stop
    }
}

# Adapted from PowerView by @harmj0y and @mattifestation
function Local:New-ThreadedFunction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True, ValueFromPipelineByPropertyName = $True)]
        [String[]]
        $Collection,

        [ValidateNotNullOrEmpty()]
        [String]
        $CollectionParameter = 'ComputerName',

        [Parameter(Mandatory = $True)]
        [ScriptBlock]
        $ScriptBlock,

        [Hashtable]
        $ScriptParameters,

        [Int]
        [ValidateRange(1,  100)]
        $Threads = 10,

        [Switch]
        $NoImports
    )

    BEGIN {
        $SessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

        # Force a single-threaded apartment state (for token-impersonation stuffz)
        $SessionState.ApartmentState = [Threading.ApartmentState]::STA

        # Import the current session state's variables and functions so the chained functionality can be used by the threaded blocks
        if (-not $NoImports) {
            # Grab all the current variables for this runspace
            $MyVars = Get-Variable -Scope 2

            # These variables are added by Runspace.Open() method and produce Stop errors if added twice
            $VorbiddenVars = @('?','args','ConsoleFileName','Error','ExecutionContext','false','HOME','Host','input','InputObject','MaximumAliasCount','MaximumDriveCount','MaximumErrorCount','MaximumFunctionCount','MaximumHistoryCount','MaximumVariableCount','MyInvocation','null','PID','PSBoundParameters','PSCommandPath','PSCulture','PSDefaultParameterValues','PSHOME','PSScriptRoot','PSUICulture','PSVersionTable','PWD','ShellId','SynchronizedHash','true')

            # Add variables from Parent Scope (current runspace) into the InitialSessionState
            foreach ($Var in $MyVars) {
                if ($VorbiddenVars -NotContains $Var.Name) {
                    $SessionState.Variables.Add((New-Object -TypeName Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Var.name,$Var.Value,$Var.description,$Var.options,$Var.attributes))
                }
            }

            # Add functions from current runspace to the InitialSessionState
            foreach ($Function in (Get-ChildItem Function:)) {
                $SessionState.Commands.Add((New-Object -TypeName Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function.Name, $Function.Definition))
            }
        }

        # Create a pool of $Threads runspaces
        $Pool = [RunspaceFactory]::CreateRunspacePool(1, $Threads, $SessionState, $Host)
        $Pool.Open()

        # Get the proper BeginInvoke() method that allows for an output queue
        $Method = $null
        foreach ($M in [PowerShell].GetMethods() | Where-Object { $_.Name -eq 'BeginInvoke' }) {
            $MethodParameters = $M.GetParameters()
            if (($MethodParameters.Count -eq 2) -and $MethodParameters[0].Name -eq 'input' -and $MethodParameters[1].Name -eq 'output') {
                $Method = $M.MakeGenericMethod([Object], [Object])
                break
            }
        }

        $Jobs = @()
        $Collection = $Collection | Where-Object {$_ -and $_.Trim()}
        Write-Verbose "[THREAD] Processing $($Collection.Count) elements with $Threads threads."

        foreach ($Element in $Collection) {
            # Create a "powershell pipeline runner"
            $PowerShell = [PowerShell]::Create()
            $PowerShell.runspacepool = $Pool

            # Add the script block and arguments
            $null = $PowerShell.AddScript($ScriptBlock).AddParameter($CollectionParameter, $Element)
            if ($ScriptParameters) {
                foreach ($Param in $ScriptParameters.GetEnumerator()) {
                    $null = $PowerShell.AddParameter($Param.Name, $Param.Value)
                }
            }

            # Create the output queue
            $Output = New-Object Management.Automation.PSDataCollection[Object]

            # Start job
            $Jobs += @{
                PS = $PowerShell
                Output = $Output
                Result = $Method.Invoke($PowerShell, @($null, [Management.Automation.PSDataCollection[Object]]$Output))
            }
        }
    }

    END {
        Write-Verbose "[THREAD] Executing threads"

        # Continuously loop through each job queue, consuming output as appropriate
        do {
            foreach ($Job in $Jobs) {
                $Job.Output.ReadAll()
            }
            Start-Sleep -Seconds 1
        }
        while (($Jobs | Where-Object {-not $_.Result.IsCompleted}).Count -gt 0)

        $SleepSeconds = 100
        Write-Verbose "[THREAD] Waiting $SleepSeconds seconds for final cleanup..."

        # Cleanup
        for ($i=0; $i -lt $SleepSeconds; $i++) {
            foreach ($Job in $Jobs) {
                $Job.Output.ReadAll()
                $Job.PS.Dispose()
            }
            Start-Sleep -Seconds 1
        }

        $Pool.Dispose()
        Write-Verbose "[THREAD] All threads completed"
    }
}

function Local:New-PowerExec {
    Param (
        [Parameter(Mandatory = $True)]
        [ScriptBlock]
        $ScriptBlock,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ComputerName,

        [ValidateNotNullOrEmpty()]
        [Management.Automation.PSCredential]
        [Management.Automation.Credential()]
        $Credential = [Management.Automation.PSCredential]::Empty,

        [ValidateSet('SchTask', 'WinRM', 'WMI')]
        [String]
        $Method = 'WMI'
    )

    $output = $null
    switch ($Method) {
        'WinRM' {
            try {
                $output = Invoke-Command -ScriptBlock $ScriptBlock -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
            }
            catch [Management.Automation.RuntimeException] {
                if($Error[0].FullyQualifiedErrorId -eq 'ComputerNotFound,PSSessionStateBroken') {
                    Write-Verbose "[$ComputerName] DNS resolution failed."
                }
                elseif($Error[0].FullyQualifiedErrorId -eq 'WinRMOperationTimeout,PSSessionStateBroken') {
                    Write-Verbose "[$ComputerName] Host is unreachable."
                }
                elseif($Error[0].FullyQualifiedErrorId -eq 'CannotConnect,PSSessionStateBroken') {
                    Write-Verbose "[$ComputerName] WinRM server is unavailable."
                }
                elseif($Error[0].FullyQualifiedErrorId -eq 'AccessDenied,PSSessionStateBroken') {
                    Write-Verbose "[$ComputerName] Access is denied."
                }
                else {
                    Write-Warning "[$ComputerName] Execution failed. $_"
                }
            }
        }
        'WMI' {
            try {
                $output = Invoke-WmiExec -ScriptBlock $ScriptBlock -ComputerName $ComputerName -Credential $Credential -Verbose:$false
            }
            catch [Runtime.InteropServices.COMException] {
                Write-Verbose "[$ComputerName] RPC server is unavailable."
            }
            catch [UnauthorizedAccessException] {
                Write-Verbose "[$ComputerName] Access is denied."
            }
            catch [Management.Automation.MethodInvocationException] {
                Write-Verbose "[$ComputerName] Insufficient rights."
            }
            catch [Management.Automation.RuntimeException] {
                if($Error[0].FullyQualifiedErrorId -eq 'InvokeMethodOnNull') {
                    Write-Verbose "[$ComputerName] DNS resolution failed."
                }
                else {
                    Write-Warning "[$ComputerName] Execution failed. $_"
                }
            }
        }
        'SchTask' {
            try {
                $output = Invoke-SchTaskExec -ScriptBlock $ScriptBlock -ComputerName $ComputerName -Credential $Credential -Verbose:$false
            }
            catch [Runtime.InteropServices.COMException] {
                Write-Verbose "[$ComputerName] RPC server is unavailable."
            }
            catch [UnauthorizedAccessException] {
                Write-Verbose "[$ComputerName] Access is denied."
            }
            catch [Management.Automation.MethodInvocationException] {
                Write-Verbose "[$ComputerName] Insufficient rights."
            }
            catch [Management.Automation.RuntimeException] {
                if($Error[0].FullyQualifiedErrorId -eq 'InvokeMethodOnNull') {
                    Write-Verbose "[$ComputerName] DNS resolution failed."
                }
                else {
                    Write-Warning "[$ComputerName] Execution failed. $_"
                }
            }
        }
    }
    if ($output) {
        Write-Host "[$ComputerName] Successful execution"
        Write-Output $output
    }
}

function Local:Invoke-WMIExec {
    [CmdletBinding()]
    Param (
        [ValidateNotNullOrEmpty()]
        [ScriptBlock]
        $ScriptBlock,

        [ValidateNotNullOrEmpty()]
        [String]
        $ComputerName = $env:COMPUTERNAME,

        [ValidateNotNullOrEmpty()]
        [Management.Automation.PSCredential]
        [Management.Automation.Credential()]
        $Credential = [Management.Automation.PSCredential]::Empty
    )

    BEGIN {
        try {
            $originalObject = Get-WmiObject -Class Win32_OSRecoveryConfiguration -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
            $originalProperty = $originalObject.DebugFilePath
            Write-Verbose "[WMIEXEC] Encoding payload into WMI property DebugFilePath"
            $script = ''
            $script += '[ScriptBlock]$scriptBlock = {' + $ScriptBlock.Ast.Extent.Text + '}' + [Environment]::NewLine -replace '{{','{' -replace '}}','}'
            $script += '$output = [Management.Automation.PSSerializer]::Serialize((& $scriptBlock *>&1))' + [Environment]::NewLine
            $script += '$encOutput = [Int[]][Char[]]$output -Join '',''' + [Environment]::NewLine
            $script += '$x = Get-WmiObject -Class Win32_OSRecoveryConfiguration' + [Environment]::NewLine
            $script += '$x.DebugFilePath = $encOutput' + [Environment]::NewLine
            $script += '$x.Put()'
            $encScript = [Int[]][Char[]]$script -Join ','
            $originalObject.DebugFilePath = $encScript
            $originalObject.Put() | Out-Null
        }
        catch {
            throw $_
        }
    }
    PROCESS {
        $loader = ''
        $loader += '$x = Get-WmiObject -Class Win32_OSRecoveryConfiguration; '
        $loader += '$y = [char[]][int[]]$x.DebugFilePath.Split('','') -Join ''''; '
        $loader += '$z = [ScriptBlock]::Create($y); '
        $loader += '& $z'
        $command = 'powershell -NoP -NonI -C "' + $loader + '"'
        Write-Verbose "[WMIEXEC] Running command: $command"    
        $Process = Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList $command -ComputerName $ComputerName -Credential $Credential
        $ProcessId = $Process.ProcessId
        do {
            Get-WmiObject -Class Win32_process -Filter "ProcessId='$ProcessId'" -ComputerName $ComputerName -Credential $Credential | Out-Null
            Start-Sleep -Seconds 1
        }
        until ((Get-WmiObject -Class Win32_process -Filter "ProcessId='$ProcessId'" -ComputerName $ComputerName -Credential $Credential | Where {$_.Name -eq "powershell.exe"}).ProcessID -eq $null)
    }
    END {
        Write-Verbose "[WMIEXEC] Getting output from WMI property DebugFilePath"
        $modifiedObject = Get-WmiObject -Class Win32_OSRecoveryConfiguration -ComputerName $ComputerName -Credential $Credential
        $output = [char[]][int[]]$modifiedObject.DebugFilePath.Split(',') -Join ''
        try {
            Write-Output ([Management.Automation.PSSerializer]::Deserialize($output))
        }
        catch [Management.Automation.MethodInvocationException] {
            Write-Warning "[$ComputerName] Failed to retrieve output."
        }
        finally {
            Write-Verbose "[WMIEXEC] Restoring original WMI property value: $originalProperty"
            $modifiedObject.DebugFilePath = $originalProperty
            $modifiedObject.Put() | Out-Null
        }
    }
}

function Local:Invoke-SchTaskExec {
    [CmdletBinding()]
    Param (
        [ValidateNotNullOrEmpty()]
        [ScriptBlock]
        $ScriptBlock,

        [ValidateNotNullOrEmpty()]
        [String]
        $ComputerName = $env:COMPUTERNAME,

        [ValidateNotNullOrEmpty()]
        [Management.Automation.PSCredential]
        [Management.Automation.Credential()]
        $Credential = [Management.Automation.PSCredential]::Empty,

        [ValidateSet('Dcom', 'Wsman')]
        [String]
        $Protocol = 'Dcom'
    )

    BEGIN {
        $cimOption = New-CimSessionOption -Protocol $Protocol
        try {
            if ($Credential.Username) {
                $cimSession = New-CimSession -ComputerName $ComputerName -Credential $Credential -SessionOption $cimOption -ErrorAction Stop -Verbose:$false
            }
            else {
                $cimSession = New-CimSession -ComputerName $ComputerName -SessionOption $cimOption -ErrorAction Stop -Verbose:$false
            }
        }
        catch [Microsoft.Management.Infrastructure.CimException] {
            Write-Verbose "[$ComputerName] Failed to establish CIM session."
            break
        }

        try {
            $originalObject = Get-CimInstance -Class Win32_OSRecoveryConfiguration -CimSession $cimSession -ErrorAction Stop -Verbose:$false
            $originalProperty = $originalObject.DebugFilePath
            Write-Verbose "[SCHTASKEXEC] Encoding payload into WMI property DebugFilePath"
            $script = ''
            $script += '[ScriptBlock]$scriptBlock = {' + $ScriptBlock.Ast.Extent.Text + '}' + [Environment]::NewLine -replace '{{','{' -replace '}}','}'
            $script += '$output = [Management.Automation.PSSerializer]::Serialize((& $scriptBlock *>&1))' + [Environment]::NewLine
            $script += '$encOutput = [Int[]][Char[]]$output -Join '',''' + [Environment]::NewLine
            $script += '$x = Get-WmiObject -Class Win32_OSRecoveryConfiguration' + [Environment]::NewLine
            $script += '$x.DebugFilePath = $encOutput' + [Environment]::NewLine
            $script += '$x.Put()'
            $encScript = [Int[]][Char[]]$script -Join ','
            $originalObject.DebugFilePath = $encScript
            $originalObject | Set-CimInstance -Verbose:$false
        }
        catch {
            throw $_
        }
    }
    PROCESS {
        $loader = ''
        $loader += '$x = Get-WmiObject -Class Win32_OSRecoveryConfiguration; '
        $loader += '$y = [char[]][int[]]$x.DebugFilePath.Split('','') -Join ''''; '
        $loader += '$z = [ScriptBlock]::Create($y); '
        $loader += '& $z'
        $arguments = '-NoP -NonI -C "' + $loader + '"'
        Write-Verbose "[SCHTASKEXEC] Running command: powershell.exe $arguments"
        $taskParameters = @{
            TaskName = [guid]::NewGuid().Guid
            Action = New-ScheduledTaskAction -WorkingDirectory "%windir%\System32\WindowsPowerShell\v1.0\" -Execute "powershell.exe" -Argument $arguments
            Principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest -CimSession $cimSession
        }
        $scheduledTask = Register-ScheduledTask @taskParameters -CimSession $cimSession -ErrorAction Stop
        $cimJob = $scheduledTask | Start-ScheduledTask -AsJob -ErrorAction Stop
        $cimJob | Wait-Job | Remove-Job -Force -Confirm:$False
        while (($scheduledTaskInfo = $scheduledTask | Get-ScheduledTaskInfo).LastTaskResult -eq 267009) { Start-Sleep -Milliseconds 200 }

        if ($scheduledTaskInfo.LastRunTime.Year -ne (Get-Date).Year) { 
            Write-Warning "[$ComputerName] Failed to execute scheduled task."
        }
    }
    END {
        Write-Verbose "[SCHTASKEXEC] Unregistering scheduled task $($taskParameters.TaskName)"
        $scheduledTask | Get-ScheduledTask -ErrorAction SilentlyContinue | Unregister-ScheduledTask | Out-Null

        Write-Verbose "[SCHTASKEXEC] Getting output from WMI property DebugFilePath"
        $modifiedObject = Get-CimInstance -ClassName Win32_OSRecoveryConfiguration -CimSession $cimSession -Verbose:$false -ErrorAction Stop
        $output = [char[]][int[]]$modifiedObject.DebugFilePath.Split(',') -Join ''
        try {
            Write-Output ([Management.Automation.PSSerializer]::Deserialize($output))
        }
        catch [Management.Automation.MethodInvocationException] {
            Write-Warning "[$ComputerName] Failed to retrieve output."
        }
        finally {
            Write-Verbose "[SCHTASKEXEC] Restoring original WMI property value: $originalProperty"
            $modifiedObject.DebugFilePath = $originalProperty
            $modifiedObject | Set-CimInstance -Verbose:$false

            Remove-CimSession -CimSession $cimSession
        }
    }
}