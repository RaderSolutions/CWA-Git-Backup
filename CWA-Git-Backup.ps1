<#
.SYNOPSIS
    Backs up all LabTech scripts.

.DESCRIPTION
    This script will export all LabTech sctipts in xml format to a specified destination.
    Requires the MySQL .NET connector.

.LINK
        http://www.labtechconsulting.com
        https://dev.mysql.com/downloads/connector/net/6.9.html
        
.OUTPUTS
    Default values -
    Log file stored in: $($env:windir)\LTScv\Logs\LT-ScriptExport.log
    Scripts exported to: $($env:windir)\Program Files(x86)\LabTech\Backup\Scripts
    Credentials file: $PSScriptRoot

.NOTES
    Version:        1.0
    Author:         Chris Taylor
    Website:        www.labtechconsulting.com
    Creation Date:  9/11/2015
    Purpose/Change: Initial script development

    Version:        1.1
    Author:         Chris Taylor
    Website:        www.labtechconsulting.com
    Creation Date:  9/23/2015
    Purpose/Change: Added error catching
#>

#Requires -Version 3.0 
 
Param(
    [switch]$EmptyFolderOverride,
    [switch]$ForceFullExport,
    [switch]$RebuildGitConfig,
    [switch]$Verbose
)
#region-[Declarations]----------------------------------------------------------
    
    $ScriptVersion = "2.0"
    
    $ErrorActionPreference = "Stop"

    # Redirect all output from git on stderr to stdout so posh doesn't throw lots of red text to screen
    #$env:GIT_REDIRECT_STDERR = '2>&1'
    
    #Get/Save config info
    $ConfigFile = "$PSScriptRoot\CWA-Git-Backup-Config.xml"
    if($(Test-Path $ConfigFile) -eq $false) {
        #Config file template
## DBSchemaExclusions - an array of regex to match. If matching, the whole match is removed
        $Config = [xml]@'
<Settings>
	<LogPath></LogPath>
	<BackupRoot></BackupRoot>
	<MySQLDatabase></MySQLDatabase>
	<MySQLHost></MySQLHost>
	<CredPath></CredPath>
    <LastExport>0</LastExport>
    <LTSharePath></LTSharePath>
    <LTShareExtensionFilter>*.csv *.txt *.html *.xml *.htm *.log *.rtf *.ini *.sh *.ps1 *.psm1 *.inf *.vbs *.css *.bat *.js *.rdp *.crt *.reg *.cmd *.php</LTShareExtensionFilter>
    <DBSchemaExclusions>
        <a><![CDATA[[ ]+PARTITION.* VALUES LESS THAN .* ENGINE.*,]]></a>
        <a><![CDATA[\(PARTITION.* VALUES LESS THAN .* ENGINE.*,]]></a>
        <a><![CDATA[ PARTITION.* VALUES LESS THAN .* ENGINE.*\)]]></a>
        <a><![CDATA[^[ ]+$]]></a>
    </DBSchemaExclusions>
</Settings>
'@
        try {
            #Create config file
            $default = "$($env:windir)\LTSvc\Logs"
            $Config.Settings.LogPath = "$(Read-Host "Path of log file [$default]")"
            if ($Config.Settings.LogPath -eq '') {$Config.Settings.LogPath = $default}
            $default = "${env:ProgramFiles}\LabTech\Backup\CWA-Git-Backup"
            $Config.Settings.BackupRoot = "$(Read-Host "Path of exported scripts [$default]")"
            if ($Config.Settings.BackupRoot -eq '') {$Config.Settings.BackupRoot = $default}
            $default = "labtech"
            $Config.Settings.MySQLDatabase = "$(Read-Host "Name of LabTech database [$default]")"
            if ($Config.Settings.MySQLDatabase -eq '') {$Config.Settings.MySQLDatabase = $default}
            $default = "localhost"
            if(Test-Path HKLM:\SOFTWARE\LabTech\Agent){
                ## DB Agent found, pulling sql server from there
                $default = (get-itemproperty -path "HKLM:\SOFTWARE\LabTech\Agent" -name "SQLServer").SQLServer
            }
            $Config.Settings.MySQLHost = "$(Read-Host "FQDN of LabTech DB Server [$default]")"
            if ($Config.Settings.MySQLHost -eq '') {$Config.Settings.MySQLHost = $default}
            $default = $PSScriptRoot
            $Config.Settings.CredPath = "$(Read-Host "Path of credentials [$default]")"
            if ($Config.Settings.CredPath -eq '') {$Config.Settings.CredPath = $default}
            # Pull LTShare location from registry if possible, else default to default setting.
            $default = (get-itemproperty -path "HKLM:\SOFTWARE\Wow6432Node\LabTech\Setup" -name "Local LTShare" -ErrorAction SilentlyContinue)."Local LTShare"
            If ($default -eq $null) {$default = "c:\LTShare"}
            $Config.Settings.LTSharePath = "$(Read-Host "Path to LTShare from this machine [$default]")"
            if ($Config.Settings.LTSharePath -eq '') {$Config.Settings.LTSharePath = $default}
            $Config.Save($ConfigFile)
        }
        Catch {
            $ErrorMessage = $_.Exception.Message
            $FailedItem = $_.Exception.ItemName
            Log-Error -LogPath $FullLogPath  -ErrorDesc "Error durring config creation: $FailedItem, $ErrorMessage" -ExitGracefully $True
        }
    }
    Else {
        [xml]$Config = Get-Content $ConfigFile
    }

    #Location to credentials file
    $CredPath = $Config.Settings.CredPath
    $CredFile = "$CredPath\DBCredentials.xml"
    
    #Get/Save user/password info
    if ($(Test-Path $CredPath) -eq $false) {New-Item -ItemType Directory -Force -Path $CredPath | Out-Null}
    if($(Test-Path $CredFile) -eq $false){
        "Credentials file not found, building one now."
        if(Test-Path HKLM:\SOFTWARE\LabTech\Agent){
            $response = read-host "DB Agent found on this machine, get credentials from registry? [y/n] "
            if($response -eq 'y'){
                Invoke-WebRequest -UseBasicParsing https://bit.ly/ltposh | Invoke-Expression
                $Pass = (get-itemproperty -path "HKLM:\SOFTWARE\LabTech\Agent" -name "MySQLPass").MySQLPass
                $PlaintextPass = ConvertFrom-LTSecurity $Pass
                $User = (get-itemproperty -path "HKLM:\SOFTWARE\LabTech\Agent" -name "User").User
                $SecurePassword = $PlaintextPass | ConvertTo-SecureString -AsPlainText -Force
                $creds = New-Object System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword
            }
            if($creds){
                "Creds decoded properly"
            }else{
                "Creds failed to decode"
                $creds = Get-Credential -Message "Please provide the credentials to the CWA MySQL database."
            }
        }
        $creds | Export-Clixml $CredFile -Force
    }
    
    #Log File Info
    $LogName = "CWA-Export.log"
    $LogPath = ($Config.Settings.LogPath)
    $FullLogPath = [System.IO.Path]::Combine($LogPath, $LogName)

    #Robocopy Log File Info
    $LogNameRobo = "CWA-Export-robocopy.log"
    $LogPath = ($Config.Settings.LogPath)
    $FullLogPathRobo = [System.IO.Path]::Combine($LogPath, $LogNameRobo)

    #Location to the backp repository
    $BackupRoot = $Config.Settings.BackupRoot

    #MySQL connection info
    $MySQLDatabase = $Config.Settings.MySQLDatabase
    $MySQLHost = $Config.Settings.MySQLHost
    $MySQLAdminPassword = (IMPORT-CLIXML $CredFile).GetNetworkCredential().Password
    $MySQLAdminUserName = (IMPORT-CLIXML $CredFile).GetNetworkCredential().UserName


    if($ForceFullExport){
        $Config.Settings.LastExport = "0"
        $EmptyFolderOverride = $true
    }
#endregion

#region-[Functions]------------------------------------------------------------

Function New-BackupPath {
    Param (
        [Parameter(Mandatory=$true)][string]$NewPath
    )
    $BackupPath = [System.IO.Path]::Combine($BackupRoot, $NewPath)
    New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null
    Set-Location $BackupPath
    Return $BackupPath
}

Function Export-DBSchema {
    Param(
        [switch]$info_schema,
        [Parameter(Mandatory=$true,Position=1)][string]$BackupPath,
        [Parameter(Mandatory=$true,Position=2)][string]$nameCol,
        [Parameter(Mandatory=$true,Position=3)][string]$createCol,
        [Parameter(Mandatory=$true,Position=4)][string]$createSQLQueryPrefix,
        [Parameter(Mandatory=$true,Position=5)][string]$listSQLQuery,
        [Parameter(Mandatory=$false,Position=6)][string]$listSQLQueryAdditionalConditions
    )

    ## $listSQLQueryAdditionalConditions will define additional conditions for the schema export, but will not consider it for deletions. This essentially delays diffs for things that match the $listSQLQueryAdditionalConditions
    $listSQLQueryReal = $listSQLQuery
    if($listSQLQueryAdditionalConditions){
        $listSQLQueryReal = "$listSQLQuery AND $listSQLQueryAdditionalConditions"
    }

    if($info_schema){
        $rows = Get-SQLData $listSQLQueryReal -info_schema
    }else{
        $rows = Get-SQLData $listSQLQueryReal
    }

    foreach($row in $rows.$nameCol){
        $filename = [System.IO.Path]::Combine($BackupPath, "$row.sql")        
        $SQLQuery = "$createSQLQueryPrefix ``$MySqlDataBase``.``$row``"
        ## silent continue due to certain tables failing to export config
        ## replace the auto_increment field to have sane diffs
        if($info_schema){
            $FileContent = (Get-SQLData $SQLQuery -info_schema -ErrorAction SilentlyContinue).$createCol | %{$_ -replace ' AUTO_INCREMENT=[0-9]*\b',''}
        }else{
            $FileContent = (Get-SQLData $SQLQuery -ErrorAction SilentlyContinue).$createCol | %{$_ -replace ' AUTO_INCREMENT=[0-9]*\b',''}
        }
        ## convert to string array
        $FileContentReal = ($FileContent -replace "`r").split("`n")
        foreach($Exclusion in $Config.Settings.DBSchemaExclusions.a.'#cdata-section'){
            ## way too noisy
            #if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "Filtering [$Exclusion] from $filename"}
            try{
                $FileContentReal = $FileContentReal | % {$_ -replace $Exclusion,''}
            }catch{
                $ErrorMessage = $_.Exception.Message
                Log-Error -FullLogPath $FullLogPath -ErrorDesc "Processing db exclusion [$Exclusion] from $filename - $ErrorMessage" -ExitGracefully $False
            }
            
        }
        ## exclude empty strings
        $FileContentReal | ? {$_ -ne ''} | Out-File -Force $filename
        
    }
    if($info_schema){
        $rows = Get-SQLData $listSQLQuery -info_schema
    }else{
        $rows = Get-SQLData $listSQLQuery
    }
    get-ChildItem $BackupPath -File | ? {($_.name -replace '\.sql','') -notin $rows.$nameCol} | remove-item -Force
}

function Format-Xml {
<#
.SYNOPSIS
Format the incoming object as the text of an XML document.
from https://blogs.msdn.microsoft.com/sergey_babkins_blog/2016/12/31/how-to-pretty-print-xml-in-powershell-and-text-pipelines/
#>
    param(
        ## Text of an XML document.
        [Parameter(ValueFromPipeline = $true)]
        [string[]]$Text
    )

    begin {
        $data = New-Object System.Collections.ArrayList
    }
    process {
        [void] $data.Add($Text -join "`n")
    }
    end {
        $doc=New-Object System.Xml.XmlDataDocument
        $doc.LoadXml($data -join "`n")
        $sw=New-Object System.Io.Stringwriter
        $writer=New-Object System.Xml.XmlTextWriter($sw)
        $writer.Formatting = [System.Xml.Formatting]::Indented
        $doc.WriteContentTo($writer)
        $sw.ToString()
    }
}

Function Log-Start{
  <#
  .SYNOPSIS
    Creates log file

  .DESCRIPTION
    Creates log file with path and name that is passed. Checks if log file exists, and if it does deletes it and creates a new one.
    Once created, writes initial logging data

  .PARAMETER LogPath
    Mandatory. Path of where log is to be created. Example: C:\Windows\Temp

  .PARAMETER LogName
    Mandatory. Name of log file to be created. Example: Test_Script.log
      
  .PARAMETER ScriptVersion
    Mandatory. Version of the running script which will be written in the log. Example: 1.5

  .INPUTS
    Parameters above

  .OUTPUTS
    Log file created

  .NOTES
    Version:        1.0
    Author:         Luca Sturlese
    Creation Date:  10/05/12
    Purpose/Change: Initial function development

    Version:        1.1
    Author:         Luca Sturlese
    Creation Date:  19/05/12
    Purpose/Change: Added debug mode support

    Version:        1.2
    Author:         Chris Taylor
    Creation Date:  7/17/2015
    Purpose/Change: Added directory creation if not present.
                    Added Append option
                    


  .EXAMPLE
    Log-Start -LogPath "C:\Windows\Temp" -LogName "Test_Script.log" -ScriptVersion "1.5"
  #>
    
  [CmdletBinding()]
  
  Param ([Parameter(Mandatory=$true)][string]$LogPath, [Parameter(Mandatory=$true)][string]$LogName, [Parameter(Mandatory=$true)][string]$ScriptVersion, [Parameter(Mandatory=$false)][switch]$Append)
  
  Process{
    $FullLogPath = [System.IO.Path]::Combine($LogPath, $LogName)
    #Check if file exists and delete if it does
    If((Test-Path -Path $FullLogPath) -and $Append -ne $true){
      Remove-Item -Path $FullLogPath -Force
    }

    #Check if folder exists if not create    
    If((Test-Path -PathType Container -Path $LogPath) -eq $False){
      New-Item -ItemType Directory -Force -Path $LogPath | Out-Null
    }

    #Create file and start logging
    If($(Test-Path -Path $FullLogPath) -ne $true) {
        New-Item -Path $LogPath -Name $LogName -ItemType File | Out-Null
    }

    Add-Content -Path $FullLogPath -Value "***************************************************************************************************"
    Add-Content -Path $FullLogPath -Value "Started processing at [$([DateTime]::Now)]."
    Add-Content -Path $FullLogPath -Value "***************************************************************************************************"
    Add-Content -Path $FullLogPath -Value ""
    Add-Content -Path $FullLogPath -Value "Running script version [$ScriptVersion]."
    Add-Content -Path $FullLogPath -Value ""
    Add-Content -Path $FullLogPath -Value "***************************************************************************************************"
    Add-Content -Path $FullLogPath -Value ""
  
    #Write to screen for debug mode
    Write-Debug "***************************************************************************************************"
    Write-Debug "Started processing at [$([DateTime]::Now)]."
    Write-Debug "***************************************************************************************************"
    Write-Debug ""
    Write-Debug "Running script version [$ScriptVersion]."
    Write-Debug ""
    Write-Debug "***************************************************************************************************"
    Write-Debug ""
  }
}
 
Function Log-Write{
  <#
  .SYNOPSIS
    Writes to a log file

  .DESCRIPTION
    Appends a new line to the end of the specified log file
  
  .PARAMETER LogPath
    Mandatory. Full path of the log file you want to write to. Example: C:\Windows\Temp\Test_Script.log
  
  .PARAMETER LineValue
    Mandatory. The string that you want to write to the log
      
  .INPUTS
    Parameters above

  .OUTPUTS
    None

  .NOTES
    Version:        1.0
    Author:         Luca Sturlese
    Creation Date:  10/05/12
    Purpose/Change: Initial function development
  
    Version:        1.1
    Author:         Luca Sturlese
    Creation Date:  19/05/12
    Purpose/Change: Added debug mode support

  .EXAMPLE
    Log-Write -FullLogPath "C:\Windows\Temp\Test_Script.log" -LineValue "This is a new line which I am appending to the end of the log file."
  #>
  
  [CmdletBinding()]
  
  Param ([Parameter(Mandatory=$true)][string]$FullLogPath, [Parameter(Mandatory=$true)][string]$LineValue)
  
  Process{
    Add-Content -Path $FullLogPath -Value $LineValue
    
    Write-Output $LineValue

    #Write to screen for debug mode
    Write-Debug $LineValue
  }
}
 
Function Log-Error{
  <#
  .SYNOPSIS
    Writes an error to a log file

  .DESCRIPTION
    Writes the passed error to a new line at the end of the specified log file
  
  .PARAMETER FullLogPath
    Mandatory. Full path of the log file you want to write to. Example: C:\Windows\Temp\Test_Script.log
  
  .PARAMETER ErrorDesc
    Mandatory. The description of the error you want to pass (use $_.Exception)
  
  .PARAMETER ExitGracefully
    Mandatory. Boolean. If set to True, runs Log-Finish and then exits script

  .INPUTS
    Parameters above

  .OUTPUTS
    None

  .NOTES
    Version:        1.0
    Author:         Luca Sturlese
    Creation Date:  10/05/12
    Purpose/Change: Initial function development
    
    Version:        1.1
    Author:         Luca Sturlese
    Creation Date:  19/05/12
    Purpose/Change: Added debug mode support. Added -ExitGracefully parameter functionality
                    
  .EXAMPLE
    Log-Error -FullLogPath "C:\Windows\Temp\Test_Script.log" -ErrorDesc $_.Exception -ExitGracefully $True
  #>
  
  [CmdletBinding()]
  
  Param (
    [Parameter(Mandatory=$true)][string]$FullLogPath, 
    [Parameter(Mandatory=$true)][string]$ErrorDesc, 
    [Parameter(Mandatory=$true)][boolean]$ExitGracefully
  )
  
  Process{
    Add-Content -Path $FullLogPath -Value "Error: An error has occurred [$ErrorDesc]."
  
    #Write to screen for debug mode
    Write-Debug "Error: An error has occurred [$ErrorDesc]."
    
    #If $ExitGracefully = True then run Log-Finish and exit script
    If ($ExitGracefully -eq $True){
      Write-Error $ErrorDesc
      Log-Finish -FullLogPath $FullLogPath -Limit 50000
      Break
    }
  }
}
 
Function Log-Finish{
  <#
  .SYNOPSIS
    Write closing logging data & exit

  .DESCRIPTION
    Writes finishing logging data to specified log and then exits the calling script
  
  .PARAMETER LogPath
    Mandatory. Full path of the log file you want to write finishing data to. Example: C:\Windows\Temp\Test_Script.log

  .PARAMETER NoExit
    Optional. If this is set to True, then the function will not exit the calling script, so that further execution can occur
  
  .PARAMETER Limit
    Optional. Sets the max linecount of the script.
  
  .INPUTS
    Parameters above

  .OUTPUTS
    None

  .NOTES
    Version:        1.0
    Author:         Luca Sturlese
    Creation Date:  10/05/12
    Purpose/Change: Initial function development
    
    Version:        1.1
    Author:         Luca Sturlese
    Creation Date:  19/05/12
    Purpose/Change: Added debug mode support
  
    Version:        1.2
    Author:         Luca Sturlese
    Creation Date:  01/08/12
    Purpose/Change: Added option to not exit calling script if required (via optional parameter)

    Version:        1.3
    Author:         Chris Taylor
    Creation Date:  7/17/2015
    Purpose/Change: Added log line count limit.
    
  .EXAMPLE
    Log-Finish -FullLogPath "C:\Windows\Temp\Test_Script.log"

.EXAMPLE
    Log-Finish -FullLogPath "C:\Windows\Temp\Test_Script.log" -NoExit $True
  #>
  
  [CmdletBinding()]
  
  Param ([Parameter(Mandatory=$true)][string]$FullLogPath, [Parameter(Mandatory=$false)][string]$NoExit, [Parameter(Mandatory=$false)][int]$Limit )
  
  Process{
    Add-Content -Path $FullLogPath -Value ""
    Add-Content -Path $FullLogPath -Value "***************************************************************************************************"
    Add-Content -Path $FullLogPath -Value "Finished processing at [$([DateTime]::Now)]."
    Add-Content -Path $FullLogPath -Value "***************************************************************************************************"
  
    #Write to screen for debug mode
    Write-Debug ""
    Write-Debug "***************************************************************************************************"
    Write-Debug "Finished processing at [$([DateTime]::Now)]."
    Write-Debug "***************************************************************************************************"
  
    if ($Limit){
        #Limit Log file to XX lines
        ## roll logs instead of truncate
        (Get-Content $FullLogPath -tail $Limit -readcount 0) | Set-Content $FullLogPath -Force -Encoding Unicode
    }
    #Exit calling script if NoExit has not been specified or is set to False
    If(!($NoExit) -or ($NoExit -eq $False)){
      Exit
    }    
  }
} 

Function Get-SQLData {
    <#
    .SYNOPSIS
        Executes a MySQL query aginst the LabTech Databse.

    .DESCRIPTION
        This comandlet will execute a MySQL query aginst the LabTech database.
        Requires the MySQL .NET connector.
        Original script by Dan Rose

    .LINK
        https://dev.mysql.com/downloads/connector/net/6.9.html
        https://www.cogmotive.com/blog/powershell/querying-mysql-from-powershell
        http://www.labtechconsulting.com

    .PARAMETER Query
        Input your MySQL query in double quotes.

    .INPUTS
        Pipeline

    .NOTES
        Version:        1.0
        Author:         Chris Taylor
        Website:        www.labtechconsulting.com
        Creation Date:  9/11/2015
        Purpose/Change: Initial script development
  
    .EXAMPLE
        Get-SQLData "SELECT ScriptID FROM lt_scripts"
        $Query | Get-SQLData
    #>

    Param(
        [Parameter(
        Mandatory = $true,
        ValueFromPipeline = $true)]
        [string]$Query,
        [switch]$info_schema
    )

    Begin {
        $ConnectionString = "server=" + $MySQLHost + ";port=3306;uid=" + $MySQLAdminUserName + ";pwd=" + $MySQLAdminPassword
        if(-not $info_schema){
            $ConnectionString +=  ";database="+$MySQLDatabase
        }else{
            $ConnectionString +=  ";database=information_schema"
        }
    }

    Process {
        Try {
          [void][System.Reflection.Assembly]::LoadWithPartialName("MySql.Data")
          $Connection = New-Object MySql.Data.MySqlClient.MySqlConnection
          $Connection.ConnectionString = $ConnectionString
          $Connection.Open()

          $Command = New-Object MySql.Data.MySqlClient.MySqlCommand($Query, $Connection)
          $DataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($Command)
          $DataSet = New-Object System.Data.DataSet
          $RecordCount = $dataAdapter.Fill($dataSet, "data")
          $DataSet.Tables[0]
        }

        Catch {
          Log-Error -FullLogPath $FullLogPath  -ErrorDesc "Unable to run query : $query" -ExitGracefully $False
        }
    }

    End {
      $Connection.Close()
    }
}

function Get-CompressedByteArray {
    ##############################
    #.SYNOPSIS
    #Function pulled from example script: https://gist.github.com/marcgeld/bfacfd8d70b34fdf1db0022508b02aca
    #
    #.DESCRIPTION
    #Long description
    #
    #.PARAMETER byteArray
    #Parameter description
    #
    #.EXAMPLE
    #An example
    #
    #.NOTES
    #General notes
    ##############################
    [CmdletBinding()]
    Param (
    [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [byte[]] $byteArray = $(Throw("-byteArray is required"))
    )
    Process {
        Write-Verbose "Get-CompressedByteArray"
            [System.IO.MemoryStream] $output = New-Object System.IO.MemoryStream
        $gzipStream = New-Object System.IO.Compression.GzipStream $output, ([IO.Compression.CompressionMode]::Compress)
            $gzipStream.Write( $byteArray, 0, $byteArray.Length )
        $gzipStream.Close()
        $output.Close()
        $tmp = $output.ToArray()
        Write-Output $tmp
    }
}
    
    
function Get-DecompressedByteArray {
##############################
#.SYNOPSIS
#Function pulled from example script: https://gist.github.com/marcgeld/bfacfd8d70b34fdf1db0022508b02aca
#
#.DESCRIPTION
#Long description
#
#.PARAMETER byteArray
#Parameter description
#
#.EXAMPLE
#An example
#
#.NOTES
#General notes
##############################
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [byte[]] $byteArray = $(Throw("-byteArray is required"))
    )
    Process {
        Write-Verbose "Get-DecompressedByteArray"
        $input = New-Object System.IO.MemoryStream( , $byteArray )
        $output = New-Object System.IO.MemoryStream
        $gzipStream = New-Object System.IO.Compression.GzipStream $input, ([IO.Compression.CompressionMode]::Decompress)
        $gzipStream.CopyTo( $output )
        $gzipStream.Close()
        $input.Close()
        [byte[]] $byteOutArray = $output.ToArray()
        Write-Output $byteOutArray
    }
}

Function Unpack-LTXML {
    <#
    .SYNOPSIS
        Unpacks an LT XML export to include ScriptData and LicenseData in human-readable format.

    .DESCRIPTION
        This commandlet will read an LT XML file and replace ScriptData and LicenseData
         
    .PARAMETER FileName
        Full name of exported XML script. Will be read and re-written as $FileName -replace "\.xml$",".unpacked.xml"

    .NOTES
        
  
    .EXAMPLE
        Unpack-LTXML -FileName c:\test\ltscript.xml
    #>

    [CmdletBinding()]
        Param(
        [Parameter(Mandatory=$True,Position=1)]
        [string]$FileName
    )
    #Write-Output "Unpacking script: $FileName"

    [System.Text.Encoding] $enc = [System.Text.Encoding]::UTF8
    $xmlcontent = [xml](Get-Content $FileName)

    $data = $xmlcontent.LabTech_Expansion.PackedScript.NewDataSet.Table.LicenseData
    [byte[]]$dataByteArray = [System.Convert]::FromBase64String($data)


    $decompressedByteArray = Get-DecompressedByteArray -byteArray $dataByteArray

    $xmlData = [xml]($enc.GetString( $decompressedByteArray ))

    $null = $xmlcontent.LabTech_Expansion.PackedScript.NewDataSet.Table.AppendChild($xmlcontent.ImportNode($xmlData.LicenseData,$true))

    $data = $xmlcontent.LabTech_Expansion.PackedScript.NewDataSet.Table.ScriptData
    [byte[]]$dataByteArray = [System.Convert]::FromBase64String($data)


    $decompressedByteArray = Get-DecompressedByteArray -byteArray $dataByteArray

    $xmlData = [xml]($enc.GetString( $decompressedByteArray ))

    # Replace actionIDs, functionids, etc with names and descriptions
    foreach($ScriptStep in $($xmlData.ScriptData.ScriptSteps)){
        $null = $ScriptStep.RemoveChild($ScriptStep.SelectSingleNode('Sort'))
        foreach($type in "action","FunctionID","Continue","OSLimit"){
            $typeDetails = $null
            switch($type){
                "action" {$typeDetails = $scriptFunctionConstantsPSObject.Actions."$($ScriptStep.$type)"} 
                "FunctionID" {$typeDetails = $scriptFunctionConstantsPSObject.Functions."$($ScriptStep.$type)".Name}
                "Continue" {$typeDetails = $scriptFunctionConstantsPSObject.Continues."$($ScriptStep.$type)"}
                "OSLimit" {$typeDetails = $scriptFunctionConstantsPSObject.OSLimits."$($ScriptStep.$type)"}
            }
            
            if($typeDetails -eq $null ){
                $typeDetails = "Script step metadata type details unknown for id: $($ScriptStep.$type)"
            }
            $ScriptStep.$type = $typeDetails
        }
    }

    $null = $xmlcontent.LabTech_Expansion.PackedScript.NewDataSet.Table.AppendChild($xmlcontent.ImportNode($xmlData.ScriptData,$true))

    $xmlcontent.Save($($FileName -replace "\.xml$",".unpacked.xml"))
}

Function Update-TableOfContents {
    <#
    .SYNOPSIS
        Creates a table of contents for the LT scripts. This will capture script moves as well as provide links to the script xml

             
    .PARAMETER FileName
        Full name of ToC file. 

    .NOTES
        
  
    .EXAMPLE
        Update-TableOfContents -FileName c:\test\ToC.md
    #>

    [CmdletBinding()]
        Param(
        [Parameter(Mandatory=$True,Position=1)]
        [string]$FileName
    )

    "## Use this table of contents to jump to details of a script" | Out-File $FileName 
    $ToCData = @()

    ## output all scripts at base of script tree above all other folders
    $FolderScripts = Get-SQLData -query "SELECT * FROM lt_scripts WHERE FolderID=0 ORDER BY ScriptName "
    foreach($FolderScript in $FolderScripts){
        $LastUser = $FolderScript.Last_User.Substring(0, $FolderScript.Last_User.IndexOf('@'))
        $ScriptPath = "$([math]::floor($FolderScript.ScriptID / 50) * 50)/$($FolderScript.ScriptID).unpacked.xml"
        $LastDate = $FolderScript.Last_Date.ToString("yyyy-MM-dd_HH-mm-ss")
        $TOCData += ">"*$Depth + ">" + "-Script: [$($FolderScript.ScriptName)]($ScriptPath) - Last Modified By: $LastUser on $LastDate" + "  "
    }
    
    $ToCData += Write-FolderTree -Depth 0 -ParentID 0

    
    $ToCData | Out-File $FileName -Append
}

Function Write-FolderTree {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True,Position=1)]
        [string]$Depth,
        [Parameter(Mandatory=$True,Position=2)]
        [string]$ParentID
    )
    <#

Writes the folder structure in ASCII, with the initial indention of the Depth param:
+---A
|   +---A
|   \---B
+---B
|   \---A
|       \---A
\---C

    #>
    $Folders = Get-SQLData -query "SELECT * FROM scriptfolders WHERE ParentID=$ParentID ORDER BY name "
    
    foreach($Folder in $Folders){
        # Output this folder at the right level
        <#
        "<details><summary>"
        if($Folder.FolderId -ne $Folders[$Folders.count - 1].FolderID){
            "-"*$Depth + "+" + "-" + $Folder.name
        }else{
            "-"*$Depth + "\" + "-" + $Folder.name
        }
        "</summary>"
        ""
        #>
        # insert newline before each folder
        " "
        ">"*$Depth + $Folder.name + "  "

        # Insert all folders inside of this folder
        Write-FolderTree -Depth ($Depth + 1) -ParentID $Folder.FolderID
        # Insert Script links
        $FolderScripts = Get-SQLData -query "SELECT * FROM lt_scripts WHERE FolderID=$($Folder.FolderID) ORDER BY ScriptName "
        foreach($FolderScript in $FolderScripts){
            $LastUser = $FolderScript.Last_User.Substring(0, $FolderScript.Last_User.IndexOf('@'))
            $ScriptPath = "$([math]::floor($FolderScript.ScriptID / 50) * 50)/$($FolderScript.ScriptID).unpacked.xml"
            $LastDate = $FolderScript.Last_Date.ToString("yyyy-MM-dd_HH-mm-ss")
            ">"*$Depth + ">" + "-Script: [$($FolderScript.ScriptName)]($ScriptPath) - Last Modified By: $LastUser on $LastDate" + "  "
        }
        #"</details>"
    }
}

Function Export-LTScript {
    <#
    .SYNOPSIS
        Exports a LabTech script as an xml file.

    .DESCRIPTION
        This commandlet will execute a MySQL query aginst the LabTech database.
        Requires Get-SQLData
        
    .LINK
        http://www.labtechconsulting.com

    .PARAMETER Query
        Input your MySQL query in double quotes.
    
    .PARAMETER FilePath
        File path of exported script.

    .NOTES
        Version:        1.0
        Author:         Chris Taylor
        Website:        www.labtechconsulting.com
        Creation Date:  9/11/2015
        Purpose/Change: Initial script development
  
    .EXAMPLE
        Get-SQLData "SELECT ScriptID FROM lt_scripts" -FilePath C:\Windows\Temp
    #>

    [CmdletBinding()]
        Param(
        [Parameter(Mandatory=$True,Position=1)]
        [string]$ScriptID
    )

    #LabTech XML template
    $ExportTemplate = [xml] @"
<LabTech_Expansion
	Version="100.332"
	Name="LabTech Script Expansion"
	Type="PackedScript">
	<PackedScript>
		<NewDataSet>
			<Table>
				<ScriptId></ScriptId>
				<FolderId></FolderId>
				<ScriptName></ScriptName>
				<ScriptNotes></ScriptNotes>
				<Permission></Permission>
				<EditPermission></EditPermission>
				<ComputerScript></ComputerScript>
				<LocationScript></LocationScript>
				<MaintenanceScript></MaintenanceScript>
				<FunctionScript></FunctionScript>
				<LicenseData></LicenseData>
				<ScriptData></ScriptData>
				<ScriptVersion></ScriptVersion>
				<ScriptGuid></ScriptGuid>
				<ScriptFlags></ScriptFlags>
				<Parameters></Parameters>
			</Table>
		</NewDataSet>
		<ScriptFolder>
			<NewDataSet>
				<Table>
					<FolderID></FolderID>
					<ParentID></ParentID>
					<Name></Name>
					<GUID></GUID>
				</Table>
			</NewDataSet>
		</ScriptFolder>
	</PackedScript>
</LabTech_Expansion>
"@

    #Query MySQL for script data.
    $ScriptXML = Get-SQLData -query "SELECT * FROM lt_scripts WHERE ScriptID=$ScriptID"
    $ScriptData = Get-SQLData -query "SELECT CONVERT(ScriptData USING utf8) AS Data FROM lt_scripts WHERE ScriptID=$ScriptID"
    $ScriptLicense = Get-SQLData -query "SELECT CONVERT(LicenseData USING utf8) AS License FROM lt_scripts WHERE ScriptID=$ScriptID"
    $LTVersion = Get-SQLData -Query "SELECT CONCAT(majorversion,'.',minorversion) AS LTVersion FROM config"

    #Save script data to the template.
    $ExportTemplate.LabTech_Expansion.Version = "$($LTVersion.LTVersion)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.ScriptId = "$($ScriptXML.ScriptId)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.FolderId = "$($ScriptXML.FolderId)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.ScriptName = "$($ScriptXML.ScriptName)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.ScriptNotes = "$($ScriptXML.ScriptNotes)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.Permission = "$($ScriptXML.Permission)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.EditPermission = "$($ScriptXML.EditPermission)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.ComputerScript = "$($ScriptXML.ComputerScript)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.LocationScript = "$($ScriptXML.LocationScript)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.MaintenanceScript = "$($ScriptXML.MaintenanceScript)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.FunctionScript = "$($ScriptXML.FunctionScript)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.LicenseData = "$($ScriptLicense.License)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.ScriptData = "$($ScriptData.Data)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.ScriptVersion = "$($ScriptXML.ScriptVersion)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.ScriptGuid = "$($ScriptXML.ScriptGuid)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.ScriptFlags = "$($ScriptXML.ScriptFlags)"
    $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.Parameters = "$($ScriptXML.Parameters)"
    

    #Check folder information

    #Check if script is at root and not in a folder
    If ($($ScriptXML.FolderId) -eq 0 -or !$($ScriptXML.FolderId)) {
        try {
            #Delete folder information from template
            $ExportTemplate.LabTech_Expansion.PackedScript.ScriptFolder.RemoveAll()
        }
        Catch {
            $ErrorMessage = $_.Exception.Message
            $FailedItem = $_.Exception.ItemName
            Log-Error -FullLogPath $FullLogPath  -ErrorDesc "Unable to remove folder data from XML: $FailedItem, $ErrorMessage" -ExitGracefully $True
        }
    }
    Else {   
            #Query MySQL for folder data.
            $FolderData = Get-SQLData -query "SELECT * FROM `scriptfolders` WHERE FolderID=$($ScriptXML.FolderId)"
        
            #Check if folder is no longer present. 
            if ($FolderData -eq $null) {
                Log-Write -FullLogPath $FullLogPath -LineValue "ScriptID $($ScriptXML.ScriptId) named '$($ScriptXML.ScriptName)' references folder $($ScriptXML.FolderId), this folder is no longer present. Setting to root folder."
                Log-Write -FullLogPath $FullLogPath -LineValue "It is recomended that you move this script to a folder."
            
                #Set to FolderID 0
                $ExportTemplate.LabTech_Expansion.PackedScript.NewDataSet.Table.FolderId = "0"
                $ScriptXML.FolderID = 0
            
                try {            
                    #Delete folder information from template
                    $ExportTemplate.LabTech_Expansion.PackedScript.ScriptFolder.RemoveAll()
                }
                Catch {
                    $ErrorMessage = $_.Exception.Message
                    $FailedItem = $_.Exception.ItemName
                    Log-Error -FullLogPath $FullLogPath  -ErrorDesc "Unable to remove folder data from XML: $FailedItem, $ErrorMessage" -ExitGracefully $True
                }
            }
            Else {
                #Format the folder name.
                #Remove special characters
                $FolderName = $($FolderData.Name).Replace('*','')
                $FolderName = $FolderName.Replace('/','-')
                $FolderName = $FolderName.Replace('<','')
                $FolderName = $FolderName.Replace('>','')
                $FolderName = $FolderName.Replace(':','')
                $FolderName = $FolderName.Replace('"','')
                $FolderName = $FolderName.Replace('\','-')
                $FolderName = $FolderName.Replace('|','')
                $FolderName = $FolderName.Replace('?','')
            
                # Save folder data to the template.
                $ExportTemplate.LabTech_Expansion.PackedScript.ScriptFolder.NewDataSet.Table.FolderID = "$($FolderData.FolderID)"
                $ExportTemplate.LabTech_Expansion.PackedScript.ScriptFolder.NewDataSet.Table.ParentID = "$($FolderData.ParentID)"
                $ExportTemplate.LabTech_Expansion.PackedScript.ScriptFolder.NewDataSet.Table.Name = "$($FolderData.name)"
                $ExportTemplate.LabTech_Expansion.PackedScript.ScriptFolder.NewDataSet.Table.GUID = "$($FolderData.GUID)"

                $ParentFolderData = Get-SQLData -query "SELECT * FROM `scriptfolders` WHERE FolderID=$($FolderData.ParentID)"
                while($ParentFolderData -ne $null){
                    #echo $ScriptXML.scriptid
                    
                    # Save folder data to the template.
                    
                    [xml]$ScriptFolderXML = @"
<LabTech_Expansion>
     <PackedScript>
     <ScriptFolder>
      <NewDataSet>
        <Table>
          <FolderID>$($ParentFolderData.FolderID)</FolderID>
          <ParentID>$($ParentFolderData.ParentID)</ParentID>
          <Name>$($ParentFolderData.name)</Name>
          <GUID>$($ParentFolderData.GUID)</GUID>
        </Table>
      </NewDataSet>
    </ScriptFolder>
  </PackedScript>
</LabTech_Expansion>
"@


                    $null = $ExportTemplate.LabTech_Expansion.PackedScript.AppendChild($ExportTemplate.ImportNode($ScriptFolderXML.LabTech_Expansion.PackedScript, $true))
                    
                    $ParentFolderData = Get-SQLData -query "SELECT * FROM `scriptfolders` WHERE FolderID=$($ParentFolderData.ParentID)"
                }
            }
    }

    # Always write into base directory
        try{
            $FilePath = "$((Get-Location).path)\$([math]::floor($ScriptXML.ScriptID / 50) * 50)"
            #Create folder
            New-Item -ItemType Directory -Force -Path $FilePath | Out-Null
        
            #Save XML
            $FileName = "$FilePath\$($ScriptXML.ScriptId).xml"
            $ExportTemplate.Save($FileName)
            
            ## insert ignored XML lines to document some metadata:
            $ScriptMetadata = @()
            $ScriptMetadata += "<!-- Full script path: $("$FolderName\$($ScriptXML.ScriptName)" -replace "--","-") : -->"
            $ScriptMetadata += "<!-- Script last user: $($ScriptXML.Last_User.Substring(0, $ScriptXML.Last_User.IndexOf('@'))) : -->"
            $ScriptMetadata += "<!-- Script last modified: $($ScriptXML.Last_Date.ToString("yyyy-MM-dd_HH-mm-ss")) : -->"
            $FileContent = Get-Content $FileName
            Set-Content $FileName -Value $ScriptMetadata,$FileContent

            Unpack-LTXML -FileName $FileName
        }
        Catch {
            $ErrorMessage = $_.Exception.Message
            $FailedItem = $_.Exception.ItemName
            Log-Error -FullLogPath $FullLogPath  -ErrorDesc "Unable to save script: $FailedItem, $ErrorMessage" -ExitGracefully $True
        }
    

}

Function Export-Search {
    <#
    .SYNOPSIS
        Exports a LabTech script as an xml file.

    .DESCRIPTION
        This commandlet will execute a MySQL query aginst the LabTech database.
        Requires Get-SQLData
        
    .LINK
        http://www.labtechconsulting.com

    .PARAMETER Query
        Input your MySQL query in double quotes.
    
    .PARAMETER FilePath
        File path of exported script.

    .NOTES
        Version:        1.0
        Author:         Chris Taylor
        Website:        www.labtechconsulting.com
        Creation Date:  9/11/2015
        Purpose/Change: Initial script development
  
    .EXAMPLE
        Get-SQLData "SELECT ScriptID FROM lt_scripts" -FilePath C:\Windows\Temp
    #>

    [CmdletBinding()]
        Param(
        [Parameter(Mandatory=$True,Position=1)]
        $Search
    )

    #$Search = Get-SQLData -query "SELECT * FROM `sensorchecks` WHERE SensID=$SearchID"

    #Check if script is at root and not in a folder
    If ($($Search.FolderId) -eq 0) {
        # script is at root
        $FolderName = "_"
    } Else {   
        #Query MySQL for folder data.
        $FolderData = Get-SQLData -query "SELECT * FROM `searchfolders` WHERE FolderID=$($Search.FolderId)"
    
        #Check if folder is no longer present. 
        if ($FolderData -eq $null) {
            Log-Write -FullLogPath $FullLogPath -LineValue "SearchID $($Search.SensId) references folder $($Search.FolderId), this folder is no longer present. Setting to root folder."
            Log-Write -FullLogPath $FullLogPath -LineValue "It is recomended that you move this search to a folder."
        
            #Set to FolderID 0
            $Search.FolderID = 0
            $FolderName = "_"
        }
        Else {
            #Format the folder name.
            #Remove special characters
            $FolderName = $($FolderData.Name).Replace('*','')
            $FolderName = $FolderName.Replace('/','-')
            $FolderName = $FolderName.Replace('<','')
            $FolderName = $FolderName.Replace('>','')
            $FolderName = $FolderName.Replace(':','')
            $FolderName = $FolderName.Replace('"','')
            $FolderName = $FolderName.Replace('\','-')
            $FolderName = $FolderName.Replace('|','')
            $FolderName = $FolderName.Replace('?','')
        
            ## searches have no concept of folder nesting
            #$ParentFolderData = Get-SQLData -query "SELECT * FROM `scriptfolders` WHERE FolderID=$($FolderData.ParentID)"
            #while($ParentFolderData -ne $null){
            #                        
            #    $ParentFolderData = Get-SQLData -query "SELECT * FROM `scriptfolders` WHERE FolderID=$($ParentFolderData.ParentID)"
            #}
            #
        }
    }

    # Always write into base directory
    try{
        $FilePath = "$BackupPath\$([math]::floor($Search.SensID / 50) * 50)"
        #Create folder
        New-Item -ItemType Directory -Force -Path $FilePath | Out-Null

        #Save XML
        $FileName = "$FilePath\$($Search.SensId).xml"
        
        ## insert ignored XML lines to document some metadata:
        $FileContent = @()
        $FileContent += "<!-- Full search path: $FolderName\$($Search.Name) : -->"
        $FileContent += "<!-- Search GUID: $($Search.GUID) : -->"
        $FileContent += "<!-- Search QueryType: $($Search.QueryType) : -->"
        $FileContent += "<!-- Search ListDATA: `n$($Search.ListDATA) `n: -->"
        ## create newlines in sql query for each "From" and "Where" clause
        $FileContent += "<!-- Search SQL: `n$($Search.SQL -replace ' from '," from `n" -replace ' where '," where `n")`n: -->"
        if($Search.SearchXML){
            $FileContent += $Search.SearchXML | Format-XML
        }else{
            $FileContent += "<empty>There is no SearchXML Content</empty>"
        }
        ## compare current file to new content to not update last modified if file isn't different (speeds up git add)
        $FileContentReal = $FileContent.split("`n")
        if((test-path $filename) -and -not [bool](compare-object $FileContentReal (get-content $filename))){
            ## search is unchanged
        }else{
            Set-Content $FileName -Value $FileContentReal
        }
    }
    Catch {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Log-Error -FullLogPath $FullLogPath  -ErrorDesc "Unable to save script: $FailedItem, $ErrorMessage" -ExitGracefully $True
    }
    

}
    

Function Rebuild-GitConfig {
    ##############################
    #.SYNOPSIS
    #(re)builds the git configuration for script diffs
    #
    #.DESCRIPTION
    #Prompts user for the repo URL. This repo is then cloned into the backupdirectory and pulled/pushed everytime this script finds changes in LT scripts. 
    #The URL must have embedded credentials either with ssh keys or as such: https://<username>:<password>@fqdn.com/repo.git
    #Push/pull will fail if git config doesn't include credentials
    #
    #.EXAMPLE
    #An example
    #
    #.NOTES
    #General notes
    ##############################

    Remove-Item -Recurse -Force "$BackupRoot\.git" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$BackupRoot.old" -ErrorAction SilentlyContinue
    
    Move-Item "$BackupRoot" "$BackupRoot.old" -Force
    mkdir "$BackupRoot" -ErrorAction Stop

    $RepoUrl = Read-Host "Enter the remote URL for git Repo (ensure ssh keys are setup first). Or type 'local' to initialize a local git repo." 
    if($RepoURL -eq 'local' -or $RepoURL -eq ''){
        git.exe init $BackupRoot
    }else{
        git.exe clone $RepoURL $BackupRoot
    }
    
    
    ## Merge old folder back into BackupRoot
    $null = robocopy.exe "$BackupRoot.old" "$BackupRoot" *.* /s /xo /r:0 /np
    Remove-Item -Recurse -Force "$BackupRoot.old" -ErrorAction SilentlyContinue

}

#endregion

#region-[Execution]------------------------------------------------------------
$scriptStartTime = Get-Date



try {

    if($RebuildGitConfig -eq $true){
        Rebuild-GitConfig
    }

    #Create log
    Log-Start -LogPath $LogPath -LogName $LogName -ScriptVersion $ScriptVersion -Append

    #Check backup directory
    if ((Test-Path $BackupRoot) -eq $false){New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null}
}
Catch {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Log-Error -FullLogPath $FullLogPath  -ErrorDesc "Error durring log/backup directory creation: $FailedItem, $ErrorMessage" -ExitGracefully $True
    }

Log-Write -FullLogPath $FullLogPath -LineValue "Getting list of all scripts."

Set-Location $BackupRoot
if(Test-Path "$BackupRoot\.git"){
    "Git repo found, doing a pull"
    $null = git.exe prune
    $null = git.exe reset --hard
    $null = git.exe pull --rebase 
    $null = git gc # --aggressive
}

if($ForceFullExport){
    "Forcing full export by deleting all non-hidden files in ($BackupRoot)"
    $null = dir $BackupRoot | Remove-Item -Recurse -Force
    #$null = Get-ChildItem $BackupRoot -Directory | ? name -ge 0 | Get-ChildItem -File -Include *.xml | Remove-Item -Force
}

###########################
## CWA Scripts backups
###########################

$BackupPath = New-BackupPath "Scripts"

## fix any scripts with zero for the last_date, as the Get-SQLData function doesn't like that
try{
    $null = Get-SQLData -query "SELECT * FROM lt_scripts WHERE last_date = 0"
}catch{
    $null = Get-SQLData -query "UPDATE lt_scripts SET last_date = DATE_ADD(NOW(),INTERVAL -1 DAY) WHERE last_date = 0"
}

## fix any scripts with empty last_user, as the table of contents function doesn't like that
$tempScripts = Get-SQLData -query "SELECT * FROM lt_scripts WHERE last_user not like '%@%'"
if($tempScripts.count -gt 0){
    $null = Get-SQLData -query "UPDATE lt_scripts SET last_user = 'None@localhost' WHERE last_user not like '%@%'"
}

$NewestScriptModification = Get-SQLData "SELECT last_date FROM lt_scripts ORDER BY last_date DESC LIMIT 1"
$ScriptIDs = @()
#Query list of all ScriptID's
if ($($Config.Settings.LastExport) -eq 0) {
    if((Get-ChildItem -Directory | Get-ChildItem -File | Measure-Object).count -gt 0 -and $EmptyFolderOverride -eq $false){
        Log-Write -FullLogPath $FullLogPath -LineValue "No last export implies all scripts should be exported, but the directory is not empty"
    }else{
        $ScriptIDs += Get-SQLData "SELECT ScriptID FROM lt_scripts order by ScriptID"
    }
}
else{
    $Query = $("SELECT ScriptID FROM lt_scripts WHERE Last_Date > " + "'" + $($Config.Settings.LastExport) +"' order by ScriptID")
    $ScriptIDs += Get-SQLData $Query   
}

Log-Write -FullLogPath $FullLogPath -LineValue "$(@($ScriptIDs).count) CWA Scripts to process."

#Process each ScriptID
$n = 0
foreach ($ScriptID in $ScriptIDs) {
    #Progress bar
    $n++
    Write-Progress -Activity "Backing up LT scripts to $((get-Location).path)" -Status "Processing ScriptID $($ScriptID.ScriptID)" -PercentComplete  ($n / @($ScriptIDs).count*100)
    
    # Source scriptstep metadata id mappings
    . "$PSScriptRoot\constants.ps1"

    #Export current script
    Export-LTScript -ScriptID $($ScriptID.ScriptID)
}
Write-Progress -Activity "Backing up LT scripts to $((get-Location).path)" -Completed

if($n -gt 0){
    Update-TableOfContents -FileName ".\ToC.md"
}

# delete xml files related to scripts that no longer exist

$AllScriptIDs = Get-SQLData "SELECT ScriptID FROM lt_scripts order by ScriptID"
if($AllScriptIDs.count -gt 100){
    "Deleting non-existent scripts"
    $null = Get-ChildItem -Directory | ? name -ge 0 | Get-ChildItem -File -Include *.xml | ?{$_.name.split(".")[0] -notin $AllScriptIDs.ScriptID} | Remove-Item -Force -ErrorAction SilentlyContinue
}

try {
    $Config.Settings.LastExport = "$($NewestScriptModification.Last_Date.ToString("yyy-MM-dd HH:mm:ss"))"
    $Config.Save($ConfigFile)
}
Catch {
    $ErrorMessage = $_.Exception.Message
    $FailedItem = $_.Exception.ItemName
    Log-Error -FullLogPath $FullLogPath  -ErrorDesc "Unable to update config with last export date: $FailedItem, $ErrorMessage" -ExitGracefully $True
}


###########################
## LTShare backups
###########################

$BackupPath = New-BackupPath "LTShare"

$LTShareSource = $Config.Settings.LTSharePath
$LTShareExtensionFilter = $Config.Settings.LTShareExtensionFilter
if(Test-Path $LTShareSource){
    # LTShare accessible
    # include files explicitly by extension
    # exclude Uploads dir and any dirs that start with a dot
    if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "Robocopy beginning. This can take a while for a large LTShare"}
    ## for some reason the abstraction of Extension Filters into a variable makes it not function. Resolving the variables into a flat string before invoke-expression seems to fix it
    $cmd = @"
Robocopy.exe /MIR "$LTShareSource" "$BackupPath" $LTShareExtensionFilter /XD ".*" "Uploads" /NC /MT /LOG:"$FullLogPathRobo" /R:3 /W:5 /NP /xa:H 
"@		
    invoke-expression $cmd
}else{
    "LTShare ($LTShareSource) not accessible"
}

###########################
## DB Schema backups
###########################
$TopLevel = "DB-Schema"

$BackupPath = New-BackupPath "$TopLevel\views"
Export-DBSchema -info_schema $BackupPath "table_name" "Create View" "SHOW CREATE VIEW" "select table_name from tables where table_type = 'VIEW' and table_schema = '$MySQLDataBase'"

####
$BackupPath = New-BackupPath "$TopLevel\table_schema"
Export-DBSchema -info_schema $BackupPath "table_name" "Create Table" "SHOW CREATE TABLE" "select table_name from tables where table_type = 'BASE TABLE' and table_schema = '$MySqlDatabase'" "create_time < DATE_ADD(NOW(),INTERVAL -1 HOUR)"

####
$BackupPath = New-BackupPath "$TopLevel\procedures"
Export-DBSchema -info_schema $BackupPath "name" "Create Procedure" "SHOW CREATE PROCEDURE" "SHOW PROCEDURE STATUS WHERE db = '$MySqlDatabase'"

####
$BackupPath = New-BackupPath "$TopLevel\functions"
Export-DBSchema -info_schema $BackupPath "name" "Create function" "SHOW CREATE FUNCTION" "SHOW FUNCTION STATUS WHERE db = '$MySqlDatabase'"

####
$BackupPath = New-BackupPath "$TopLevel\events"
Export-DBSchema $BackupPath "name" "Create Event" "Show create event" "Show Events"

####
###########################
## Searches backups
###########################

$BackupPath = New-BackupPath "Searches"

$Searches = @()
$Searches += Get-SQLData "SELECT * FROM sensorchecks order by SensID"

if($Searches.count -eq 0){
    Log-Error -FullLogPath $FullLogPath  -ErrorDesc "Failed to get searches: $FailedItem, $ErrorMessage" -ExitGracefully $True
}else{
    foreach($Search in $Searches){
        Export-Search $Search
    }
}
get-ChildItem -Recurse -File | ? {($_.name -replace '\.xml','') -notin $Searches.SensID} | remove-item -Force


###########################
## Git Commits
###########################

if(Test-Path "$BackupRoot\.git"){
    "Git repo found, doing a push"
    $null = git.exe config --global core.safecrlf false
    # Redirect all output from git on stderr to stdout as git's default config makes no sense on Windows
    #$env:GIT_REDIRECT_STDERR = '2>&1'

    $FoldersCommitted = @()        


### CWA Scripts commits
    if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "CWA Scripts commits"}
    $FoldersCommitted += "Scripts"
    Set-Location $BackupRoot\$($FoldersCommitted[-1])

    $scriptDirs = Get-ChildItem -Directory | ? name -ge 0
    $changedFiles = @()
    foreach($scriptDir in $scriptDirs){
        $changedFiles += Get-ChildItem $scriptDir | ? LastWriteTime -gt $scriptStartTime | select @{n='RelativePath';e={Resolve-Path -Relative $_.FullName}},
                            @{n='User';e={(Get-Content $_.fullname | select -f 2 | select -l 1 | %{$_.split(":")[1].trim()})}}
    }

### push a commit for each LT user that modified scripts
    if($ForceFullExport){
        ## not doing individual commits on initial backup
        git.exe add .\
        $commitString = "CWA Scripts initial commit"
        if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "committing $commitString"}
        $null = git.exe commit -m "$commitString"
    }else{
        foreach($user in $($changedFiles | Group-Object User).Name){     
            git add ./ToC.md | Out-Null
            $changedFiles | ? User -eq $user | %{$null = git.exe add "$($_.RelativePath)"}
            $commitString =  "CWA Script(s) Modified by User $user"
            if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "committing $commitString"}
            $null = git.exe commit -m $commitString
        }
    }

### LTShare commits (per file extension)
    if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "LTShare commits"}
    $FoldersCommitted += "LTShare"
    Set-Location $BackupRoot\$($FoldersCommitted[-1])

    if($ForceFullExport){
        ## not doing individual commits on initial backup
        git.exe add .\
        $commitString = "LTShare initial commit"
        if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "committing $commitString"}
        $null = git.exe commit -m "$commitString"
    }else{
        $files = Get-ChildItem -Recurse -File 
        $extensions = ($files | group-object Extension).Name
        Set-Location $BackupRoot
        foreach($ext in $extensions){
            $null = $files | ? Extension -eq $ext | %{$null = git.exe add "$(resolve-path -relative $_.fullname)"}
            $commitString = "Changes from .\$($FoldersCommitted[-1]) with extension $ext"
            if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "committing $commitString"}
            $null = git.exe commit -m "$commitString"
        }
    }

### Searches commits (changed during this script run)
#   $FoldersCommitted += "Searches"
#   Set-Location $BackupRoot\$($FoldersCommitted[-1])
#   
#   $files = get-ChildItem -Recurse -File | ? LastWriteTime -gt $scriptStartTime
#   Set-Location $BackupRoot
#   $null = $files | %{$null = git.exe add "$(resolve-path -relative $_.fullname)"}
#   $commitString = "Changes from .\$($FoldersCommitted[-1])"
#   if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "committing $commitString"}
#   $null = git.exe commit -m "$commitString"

### all other folder commits
    if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "Adding all non-special folders"}
    Set-Location $BackupRoot
    $dirs = @()
    $dirs += Get-ChildItem -Directory -exclude $FoldersCommitted
    $dirs += $dirs | Get-ChildItem -Directory -Recurse | ? name -notmatch '[0-9]+'
    foreach($dir in $dirs){
        Set-Location $dir.fullname
        ## Commit all directories with files, or directories that contain numerical subdirectories
        if((get-ChildItem -File).count -gt 0 -or (Get-ChildItem -Directory | ? name -match '[0-9]+').count -gt 0){
            #$null = Get-ChildItem -file | %{$null = git.exe add "$(resolve-path -relative $_.fullname)"}
            Set-Location $BackupRoot
            $RelativePath = $dir | Resolve-Path -Relative
            git.exe add "$RelativePath\."
            $commitString = "Changes from $RelativePath"
            if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "committing $commitString"}
            $null = git.exe commit -m "$commitString"
        }
    }

### finalize git push
    if($Verbose){Log-Write -FullLogPath $FullLogPath -LineValue "Finalizing commits and adding any straggler files"}
    # Build default README.md if it doesn't exist
    if($(Get-Content "README.md" -ErrorAction SilentlyContinue | Measure-Object).count -gt 1){
        # Readme contains more than one line of content. not rebuilding
    }else{
        @"
## CWA System Versioning

This repo should contain xml files from all scripts in the CWA system. If the export runs on a schedule, the commit history should provide clean auditing of changes to the scripts over time. Each script is represented by two files
- <ScriptID>.xml
- This file should be directly importable into the control center. Note that this does not contain every reference inside the script (external scripts or files are not included)
- <ScriptID>.unpacked.xml
- This file is the same as above minus the ability to import into LT, but plus the ScriptData and LicenseData fields being expanded into a human-readable format.


## Script Links

The scripts are sorted into folders based on their script ID, and [a table of contents should exist in this same directory](./Scripts/ToC.md) with mappings between script names and script IDs.

## Other various systems 

Various DB properties/schema as well as CWA system definitions (groups, searches, etc) are also backed up here

"@ | Out-File "$BackupRoot\README.md"
        git.exe add "$BackupRoot\README.md"
        git.exe commit -m "Add README" | Out-Null
    }    
    
    Set-Location $BackupRoot
    ## push the rest of the changed files
    ## very inefficient, hope to get rid of this one day
    git.exe add --all | Out-Null
    git.exe commit -m "Various files" | Out-Null

    git.exe push 
}else{
    "[$BackupRoot] is not a git repo - skipping all git actions"
}

Log-Write -FullLogPath $FullLogPath -LineValue "Export finished."

Log-Finish -FullLogPath $FullLogPath -Limit 50000


#endregion