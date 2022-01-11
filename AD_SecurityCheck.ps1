<# 
.SYNOPSIS 
    AD_SecurityCheck
    This was based on "AD-Security-Assessment" by Krishnamoorthi Gopal - https://4sysops.com/members/krishna1990/
    https://github.com/gkm-automation/AD-Security-Assessment

.DESCRIPTION 
    Pulls important security facts from Active Directory and generates nicely viewable reports in HTML format by highlighting the spots that require attention
 
.NOTES
    Version        : 0.1.1 (11 January 2022)
    Creation Date  : 10 January 2022
    Purpose/Change : Pulls important security facts from Active Directory and generates nicely viewable reports in HTML format
    File Name      : AD_SecurityCheck.ps1 
    Author         : Krishnamoorthi Gopal - https://4sysops.com/members/krishna1990/
    Modified       : Christopher Bledsoe - cbledsoe@ipmcomputers.com
    Requires       : PowerShell Version 2.0+ installed

.CHANGELOG
    0.1.0 Initial Release
          Modified script to be usable within NAble AMP Automation
          Disabled use of 'config.ini' file for inputting script settings; plan to have '$UserLogonAge' and '$UserPasswordAge' parameters passed via AMP input
          Disabled use of SMTP method for delivering reports; instead these will be saved locally under 'C:\IT\Reports'
    0.1.1 Switched to using 'TimeSpan.CompareTo()' for evaluating '$DomainPasswordPolicy.MinPasswordAge' and '$DomainPasswordPolicy.MaxPasswordAge'
            This was due to what I can only call a 'bug' in the behaviour of the comparisons when PS suddenly stopped comparing '$DomainPasswordPolicy.MaxPasswordAge' to '60' properly

.TODO
    Probably best to switch all 'TimeSpan' objects to using 'TimeSpan.CompareTo()' to avoid any future issues with comparisons
#>

# First Clear any variables
Remove-Variable * -ErrorAction SilentlyContinue

#REGION ----- DECLARATIONS ----
$global:o_Domain = ""
$global:o_PDC = ""
#PASSWORDS
$global:o_PwdComplex = ""
$global:o_MinPwdLen = ""
$global:o_MinPwdAge = ""
$global:o_MinPwdAgeFlag = $true
$global:o_MaxPwdAge = ""
$global:o_MaxPwdAgeFlag = $true
$global:o_PwdHistory = ""
$global:o_RevEncrypt = ""
#LOCKOUT
$global:o_LockThreshold = ""
$global:o_LockDuration = ""
$global:o_LockDurationFlag = $true
$global:o_LockObserve = ""
$global:o_LockObserveFlag = $true
#USERS
$global:o_TotalUser = ""
$global:o_EnabledUser = ""
$global:o_DisabledUser = ""
$global:o_InactiveUser = ""
$global:o_PwdNoExpire = ""
$global:o_SIDHistory = ""
$global:o_RevEncryptUser = ""
$global:o_PwdNoRequire = ""
$global:o_KerbUser = ""
$global:o_KerbPreAuthUser = ""
#NOTES
$global:o_Notes = " "
#ENDREGION ----- DECLARATIONS ----

#---------------------------------------------------------------------------------------------------------------------------------------------
# Functions Section
#---------------------------------------------------------------------------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Message,
 
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Information','Warning','Error')]
        [string]$Severity = 'Information'
    )
    $LogContent = (Get-Date -f g)+" " + $Severity +"  "+$Message
    Add-Content -Path $logFile -Value $LogContent -PassThru | Write-Host

}

function Get-IniContent ($filePath) {
  $ini = @{}
  switch -regex -file $FilePath {
    �^\[(.+)\]� { # Section
      $section = $matches[1]
      $ini[$section] = @{}
      $CommentCount = 0
    }
    �^(;.*)$� { # Comment
      $value = $matches[1]
      $CommentCount = $CommentCount + 1
      $name = �Comment� + $CommentCount
      $ini[$section][$name] = $value
    }
    �(.+?)\s*=(.*)� { # Key
      $name,$value = $matches[1..2]
      $ini[$section][$name] = $value
    }
  }
  return $ini
}
#ENDREGION ----- FUNCTIONS ----

#------------
#BEGIN SCRIPT
#CHECK 'PERSISTENT' FOLDERS
if (-not (test-path -path "C:\temp")) {
  new-item -path "C:\temp" -itemtype directory
}
if (-not (test-path -path "C:\IT")) {
  new-item -path "C:\IT" -itemtype directory
}
if (-not (test-path -path "C:\IT\Scripts")) {
  new-item -path "C:\IT\Scripts" -itemtype directory
}
if (-not (test-path -path "C:\IT\Reports")) {
  new-item -path "C:\IT\Reports" -itemtype directory
}
if (-not (test-path -path "C:\IT\Log")) {
  new-item -path "C:\IT\Log" -itemtype directory
}

# Start script execution time calculation
$ScrptStartTime = (Get-Date).ToString('dd-MM-yyyy hh:mm:ss')
$sw = [Diagnostics.Stopwatch]::StartNew()

# Get Script Directory
$Scriptpath = $($MyInvocation.MyCommand.Path)
$Dir = "C:\IT";

# Report
$runntime= (get-date -format dd_MM_yyyy-HH_mm_ss)-as [string]
$HealthReport = $Dir + "\Reports\ADsecurity" + "$runntime" + ".htm"

# Logfile 
$Logfile = $Dir + "\Log\ADsecurity" + "$runntime" + ".log"

#import AD Module
try {
 Import-Module ActiveDirectory   
} catch [System.Management.Automation.ParameterBindingException] {
  Write-Log -Message "Failed Importing Active Directory Module..!" -Severity Error
  Break;
}

#Import Configuration Params
#$params = Get-IniContent -filePath "$dir\Config.ini"

# E-mail report details
#$SendEmail     = $params.SMTPSettings.SendEmail.Trim()
#$emailFrom     = $params.SMTPSettings.EmailFrom.Trim()
#$emailTo       = $params.SMTPSettings.EmailTo.Trim()
#$smtpServer    = $params.SMTPSettings.SmtpServer.Trim()
#$emailSubject  = $params.SMTPSettings.EmailSubject.Trim()

$UserLogonAge=180
$UserPasswordAge=180
$strComputer = $env:computername
$strWMI = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select Domain
$DCtoConnect = $strComputer + "." + $strWMI.domain
#$DCtoConnect = $params.Config.ConnectorDC.Trim()
[string]$date = Get-Date
$DCList = @()

#---------------------------------------------------------------------------------------------------------------------------
# Setting the header for the Report
#---------------------------------------------------------------------------------------------------------------------------
[DateTime]$DisplayDate = ((get-date).ToUniversalTime())
$header = "
  <!DOCTYPE html>
		<html>
		<head>
      <link rel='shortcut icon' href='favicon.png' type='image/x-icon'>
      <meta charset='utf-8'>
      <meta name='viewport' content='width=device-width, initial-scale=1.0'>		
      <title>AD Security Check</title>
      <script type=""text/javascript"">
        function Powershellparamater(htmlTable) {
          var myWindow = window.open('', '_blank');
          myWindow.document.write(htmlTable);
        }
        window.onscroll = function () {
          if (window.pageYOffset == 0) {
            document.getElementById(""toolbar"").style.display = ""none"";
          } else {
            if (window.pageYOffset > 150) {
              document.getElementById(""toolbar"").style.display = ""block"";
            }
          }
        }
        function HideTopButton() {
          document.getElementById(""toolbar"").style.display = ""none"";
        }
      </script>
      <style>
        <style>
        #toolbar {
          position: fixed;
          width: 100%;
          height: 25px;
          top: 0;
          left: 0;
          /**/
          text-align: right;
          display: none;
        }
        #backToTop {
          font-family: Segoe UI;
          font-weight: bold;
          font-size: 20px;
          color: #9A2701;
          background-color: #ffffff;
        }
        #Reportrer {
          width: 95%;
          margin: 0 auto;
        }
        body {
          color: #333333;
          font-family: Calibri,Tahoma;
          font-size: 10pt;
          background-color: #616060;
        }
        .odd {
          background-color: #ffffff;
        }
        .even {
          background-color: #dddddd;
        }
        table {
          background-color: #616060;
          width: 100%;
          color: #fff;
          margin: auto;
          border: 1px groove #000000;
          border-collapse: collapse;
        }
        caption {
          background-color: #D9D7D7;
          color: #000000;
        }
        .bold_class {
          background-color: #ffffff;
          color: #000000;
          font-weight: 550;
        }
        td {
          text-align: left;
          font-size: 14px;
          color: #000000;
          background-color: #F5F5F5;
          border: 1px groove #000000;
          -webkit-box-shadow: 0px 10px 10px -10px #979696;
          -moz-box-shadow: 0px 10px 10px -10px #979696;
          box-shadow: 0px 2px 2px 2px #979696;
        }
        td a {
          text-decoration: none;
          color:blue;
          word-wrap: Break-word;
        }
        th {
          background-color: #7D7D7D;
          text-align: center;
          font-size: 14px;
          border: 1px groove #000000;
          word-wrap: Break-word;
          -webkit-box-shadow: 0px 10px 10px -10px #979696;
          -moz-box-shadow: 0px 10px 10px -10px #979696;
          box-shadow: 0px 2px 2px 2px #979696;
        }
        #container {
          width: 98%;
          background-color: #616060;
          margin: 0px auto;
          overflow-x:auto;
          margin-bottom: 20px;
        }
        #scriptexecutioncontainer {
          width: 80%;
          background-color: #616060;
          overflow-x:auto;
          margin-bottom: 30px;
          margin: auto;
        }
        #discovercontainer {
          width: 80%;
          background-color: #616060;
          overflow-x:auto;
          padding-top: 30px;
          margin-bottom: 30px;
          margin: auto;
        }
        #portsubcontainer {
          float: left;
          width: 48%;
          height: 250px;
          overflow-x:auto;
          overflow-y:auto;
        }
        #DomainUserssubcontainer {
          float: right;
          width: 48%;
          height: 250px;
          overflow-x:auto;
          overflow-y:auto;
        }
        #pwdplysubcontainer {
          float: left;
          width: 48%;
          height: 200px;
          overflow-x:auto;
          overflow-y:auto;
        }
        #delegationsubcontainer {
          float: left;
          width: 48%;
          height: 120px;
          overflow-x:auto;
          overflow-y:auto;
        }
        #gpppwdsubcontainer {
          float: right;
          width: 48%;
          height: 120px;
          overflow-x:auto;
          overflow-y:auto;
        }
        #TLBkbsubcontainer {
          float: right;
          width: 48%;
          height: 200px;
          overflow-x:auto;
          overflow-y:auto;
        }
        #krbtgtcontainer {
          width: 100%;
          overflow-y: auto;
          overflow-x:auto;
          height: 100px;
        }
        #groupsubcontainer {
          float: left;
          width: 48%;
          height: 200px;
          overflow-x:auto;
          overflow-y:auto;
        }
        .error {
          text-color: #FE5959;
          text-align: left;
        }
        #titleblock {
          display: block;
          float: center;
          margin-left: 25%;
          margin-right: 25%;
          width: 100%;
          position: relative;
          text-align: center
          background-image:
        }
        #header img {
          float: left;
          width: 190px;
          height: 130px;
          /*background-color: #fff;*/
        }
        .title_class {
          color: #3B1400;
          text-shadow: 0 0 1px #F42121, 0 0 1px #0A8504, 0 0 2px white;
          font-size:58px;
          text-align: center;
        }
        .passed {
          background-color: #6CCB19;
          text-align: left;
          color: #000000;
        }
        .failed {
          background-color: #FA6E59;
          text-align: left;
          color: #000000;
          text-decoration: none;
        }
        #headingbutton {
          display: inline-block;
          padding-top: 8px;
          padding-bottom: 8px;
          background-color: #D9D7D7;
          font-size: 16px
          font-family: 'Trebuchet MS', Arial, Helvetica, sans-serif;
          font-weight: bold;
          color: #000;
          width: 12%;
          text-align: center;
          -webkit-box-shadow: 0px 1px 1px 1px #979696;
          -moz-box-shadow: 0px 1px 1px 1px #979696;
          box-shadow: 0px 1px 1px 1px #979696;
        }
        #headingtabsection {
          width: 96%;
          margin-right: 50px;
          margin-left: 55px;
          margin-bottom: 30px;
          margin-bottom: 50px;
        }
        #headingbutton:active {
          background-color: #7C2020;
        }
        #headingbutton:hover {
          background-color: #7C2020;
          color: #ffffff;
        }
        #headingbutton:hover {
          background-color: #ffffff;
          color: #000000;
        }
        #headingbutton a {
          color: #000000;
          font-size: 16px;
          text-decoration: none;
        }
        #header {
          width: 100%
          padding: 10px;
          text-align: center;
          color: #3B1400;
          color: white;
          text-shadow: 8px 8px 12px #000000;
          font-size:50px;
          background-color: #616060;
        }
        #headerdate {
          color: #ffffff;
          font-size:16px;
          font-weight: bold;
          margin-bottom: 5px;
          text-align: right;	
        }
        /* Tooltip container */
        .tooltip {
          position: relative;
          display: inline-block;
          border-bottom: 1px dotted black; /* If you want dots under the hoverable text */
        }
        /* Tooltip text */
        .tooltip .tooltiptext {
          visibility: hidden;
          width: 180px;
          background-color: black;
          color: #fff;
          text-align: center;
          padding: 5px 0;
          border-radius: 6px;
          /* Position the tooltip text - see examples below! */
          position: absolute;
          z-index: 1;
        }
        /* Show the tooltip text when you mouse over the tooltip container */
        .tooltip:hover .tooltiptext {
          visibility: visible;
          right: 105%; 
        }
      </style>
    </head>
    <body>
      <div id=header>
        AD Security Check Report
      </div> 
      <div id=headerdate>
        $DisplayDate
      </div>"
Add-Content $HealthReport $header

#---------------------------------------------------------------------------------------------------------------------------
# Domain INfo
#---------------------------------------------------------------------------------------------------------------------------
try { 
  $Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()  
} catch { 
  Write-Log "Cannot connect to current Domain."
  Break;
}
$Domain.DomainControllers | ForEach-Object {$DCList += $_.Name}

if (!$DCList) {
  Write-Log "No Domain Controller found. Run this solution on AD server. Please try again."
  Break;
}
Write-Log "List of Domain Controllers Discovered"
# List out all machines discovered in Log File and Console
foreach ($D in $DCList) {Write-Log "$D"}
Add-Content $HealthReport $dataRow

# Check if any domain controllers left
if ($DCList.Count -eq 0) {
  Write-Log -Message "As no machines left script won't continue further" -Severity Error
  Break
}
# Start Container Div and Sub container div
$dataRow = "<div id=container><div id=portsubcontainer>"
$dataRow += "<table border=1px>
<caption><h2><a name='Domain Info'>Domain Info</h2></caption>"
$forestinfo = Get-ADForest -Server $DCtoConnect
$domaininfo = Get-ADDomain -Server $DCtoConnect
$dataRow += "<tr>
<td class=bold_class>ForestName</td>
<td >$($($forestinfo.Name).ToUpper())</td>
</tr>"
$dataRow += "<tr>
<td class=bold_class>DomainName</td>
<td >$($($domaininfo.Name).ToUpper())</td>
</tr>"
$dataRow += "<tr>
<td class=bold_class>ForestMode(FFL)</td>
<td >$($forestinfo.ForestMode)</td>
</tr>"
$dataRow += "<tr>
<td class=bold_class>DomainMode(DFL)</td>
<td >$($domaininfo.DomainMode)</td>
</tr>"
$dataRow += "<tr>
<td class=bold_class>SchemaMaster</td>
<td >$($forestinfo.SchemaMaster)</td>
</tr>"
$dataRow += "<tr>
<td class=bold_class>DomainNamingMaster</td>
<td >$($forestinfo.DomainNamingMaster)</td>
</tr>"
$dataRow += "<tr>
<td class=bold_class>PDCEmulator</td>
<td >$($domaininfo.PDCEmulator)</td>
</tr>"
$dataRow += "<tr>
<td class=bold_class>RIDMaster</td>
<td >$($domaininfo.DomainMode)</td>
</tr>"
$dataRow += "<tr>
<td class=bold_class>InfrastructureMaster</td>
<td >$($domaininfo.InfrastructureMaster)</td>
</tr>"
Add-Content $HealthReport $dataRow
Add-Content $HealthReport "</table></div>" # End Sub Container Div

#---------------------------------------------------------------------------
# Domain Users Validation
#---------------------------------------------------------------------------
Write-Log -Message "Performing Domain Users Validation..............."
# Start Sub Container
$DomainUsers= "<Div id=DomainUserssubcontainer><table border=1px>
   <caption><h2><a name='DomainUsers'>Domain Users</h2></caption>"
Add-Content $HealthReport $DomainUsers
## Get Domain User Information
#$LastLoggedOnDate = $(Get-Date) - $(New-TimeSpan -days $params.Config.UserLogonAge)
#$PasswordStaleDate = $(Get-Date) - $(New-TimeSpan -days $params.Config.UserPasswordAge)
$LastLoggedOnDate = $(Get-Date) - $(New-TimeSpan -days $UserLogonAge)  
$PasswordStaleDate = $(Get-Date) - $(New-TimeSpan -days $UserPasswordAge)
$ADLimitedProperties = @("Name","Enabled","SAMAccountname","DisplayName","Enabled","LastLogonDate","PasswordLastSet","PasswordNeverExpires","PasswordNotRequired","PasswordExpired","SmartcardLogonRequired","AccountExpirationDate","AdminCount","Created","Modified","LastBadPasswordAttempt","badpwdcount","mail","CanonicalName","DistinguishedName","ServicePrincipalName","SIDHistory","PrimaryGroupID","UserAccountControl")

[array]$DomainUsers = Get-ADUser -Filter * -Property $ADLimitedProperties -Server $DCtoConnect 
[array]$DomainEnabledUsers = $DomainUsers | Where {$_.Enabled -eq $True }
[array]$DomainDisabledUsers = $DomainUsers | Where {$_.Enabled -eq $false }
[array]$DomainEnabledInactiveUsers = $DomainEnabledUsers | Where { ($_.LastLogonDate -le $LastLoggedOnDate) -AND ($_.PasswordLastSet -le $PasswordStaleDate) }
[array]$DomainUsersWithReversibleEncryptionPasswordArray = $DomainUsers | Where { $_.UserAccountControl -band 0x0080 } 
[array]$DomainUserPasswordNotRequiredArray = $DomainUsers | Where {$_.PasswordNotRequired -eq $True}
[array]$DomainUserPasswordNeverExpiresArray = $DomainUsers | Where {$_.PasswordNeverExpires -eq $True}
[array]$DomainKerberosDESUsersArray = $DomainUsers | Where { $_.UserAccountControl -band 0x200000 }
[array]$DomainUserDoesNotRequirePreAuthArray = $DomainUsers | Where {$_.DoesNotRequirePreAuth -eq $True}
[array]$DomainUsersWithSIDHistoryArray = $DomainUsers | Where {$_.SIDHistory -like "*"}

$domainusersrow = "<thead><tbody><tr>
<td class=bold_class>Total Users</td>
<td width='40%' style= 'text-align: center'>$($DomainUsers.Count)</td>
</tr>"
$domainusersrow += "<tr>
<td class=bold_class>Enabled Users</td>
<td width='40%' style= 'text-align: center'>$($DomainEnabledUsers.Count)</td>
</tr>"
$domainusersrow += "<tr>
<td class=bold_class>Disabled Users</td>
<td width='40%' style= 'text-align: center'>$($DomainDisabledUsers.Count)</td>
</tr>"
$domainusersrow += "<tr>
<td class=bold_class>Inactive Users</td>
<td width='40%' style= 'text-align: center'>$($DomainEnabledInactiveUsers.Count)</td>
</tr>"
$domainusersrow += "<tr>
<td class=bold_class>Users With Password Never Expires</td>
<td width='40%' style= 'text-align: center'>$($DomainUserPasswordNeverExpiresArray.Count)</td>
</tr>"
$domainusersrow += "<tr>
<td class=bold_class>Users With SID History</td>
<td width='40%' style= 'text-align: center'>$($DomainUsersWithSIDHistoryArray.Count)</td>
</tr>"

If ($($DomainUsersWithReversibleEncryptionPasswordArray.Count) -gt 0) {
  $temp = @()
  $DomainUsersWithReversibleEncryptionPasswordArray | ForEach-Object { $temp = $temp + $_.SamAccountName + "<br>" }
  $domainusersrow += "<tr>
  <td class=bold_class>Users With ReversibleEncryptionPasswordArray</td>
  <td class=failed width='40%' style= 'text-align: center'><a href='javascript:void(0)' onclick=""Powershellparamater('"+ $temp +"')"">$($DomainUsersWithReversibleEncryptionPasswordArray.Count)</a></td>
  </tr>" 
} else {
  $domainusersrow += "<tr>
  <td class=bold_class>Users With ReversibleEncryptionPasswordArray</td>
  <td class=passed width='40%' style= 'text-align: center'>$($DomainUsersWithReversibleEncryptionPasswordArray.Count)</td>
  </tr>" 
}

If ($($DomainUserPasswordNotRequiredArray.Count) -gt 0) {
  $temp = @()
  $DomainUserPasswordNotRequiredArray | ForEach-Object { $temp = $temp + $_.SamAccountName + "<br>" }
  $domainusersrow += "<tr>
  <td class=bold_class>Users With Password Not Required</td>
  <td class=failed width='40%' style= 'text-align: center'><a href='javascript:void(0)' onclick=""Powershellparamater('"+ $temp +"')"">$($DomainUserPasswordNotRequiredArray.Count)</a></td>
  </tr>" 
} else {
  $domainusersrow += "<tr>
  <td class=bold_class>Users With Password Not Required</td>
  <td class=passed width='40%' style= 'text-align: center'>$($DomainUserPasswordNotRequiredArray.Count)</td>
  </tr>" 
}

If ($($DomainKerberosDESUsersArray.Count) -gt 0) {
  $temp = @()
  $DomainKerberosDESUsersArray | ForEach-Object { $temp = $temp + $_.SamAccountName + "<br>" }
  $domainusersrow += "<tr>
  <td class=bold_class>Users With Kerberos DES</td>
  <td class=failed width='40%' style= 'text-align: center'><a href='javascript:void(0)' onclick=""Powershellparamater('"+ $temp +"')"">$($DomainKerberosDESUsersArray.Count)</a></td>
  </tr>" 
} else {
  $domainusersrow += "<tr>
  <td class=bold_class>Users With Kerberos DES</td>
  <td class=passed width='40%' style= 'text-align: center'>$($DomainKerberosDESUsersArray.Count)</td>
  </tr>" 
}

If ($($DomainUserDoesNotRequirePreAuthArray.Count) -gt 0) {
  $temp = @()
  $DomainUserDoesNotRequirePreAuthArray | ForEach-Object { $temp = $temp + $_.SamAccountName + "<br>" }
  $domainusersrow += "<tr>
  <td class=bold_class>Users That Do Not Require Kerberos Pre-Authentication</td>
  <td class=failed width='40%' style= 'text-align: center'><a href='javascript:void(0)' onclick=""Powershellparamater('"+ $temp +"')"">$($DomainUserDoesNotRequirePreAuthArray.Count)</a></td>
  </tr>" 
} else {
  $domainusersrow += "<tr>
  <td class=bold_class>Users That Do Not Require Kerberos Pre-Authentication</td>
  <td class=passed width='40%' style= 'text-align: center'>$($DomainUserDoesNotRequirePreAuthArray.Count)</td>
  </tr>" 
}
Add-Content $HealthReport $domainusersrow
Add-Content $HealthReport "</tbody></table></div></div>" # End Sub Container Div and Container Div

#-----------------------
# Domain Password Policy 
#-----------------------
Write-Log -Message "Determining Domain Password Policy........... "
#Start Container and Sub Container Div
$Pwdpoly = "<div id=container><div id=pwdplysubcontainer><table border=1px>
            <caption><h2><a name='Pwd Policy'>Domain Password Policy</h2></caption>"
Add-Content $HealthReport $Pwdpoly
[array]$DomainPasswordPolicy = Get-ADDefaultDomainPasswordPolicy -Server $DCtoConnect
$props = @("ComplexityEnabled","DistinguishedName","LockoutDuration","LockoutObservationWindow","LockoutThreshold","MaxPasswordAge","MinPasswordAge","MinPasswordLength","PasswordHistoryCount","ReversibleEncryptionEnabled")
foreach ($item in $props) {
  $flag= 'passed'
  If (($item -eq 'ComplexityEnabled') -and ($DomainPasswordPolicy.ComplexityEnabled -ne 'True')) { $flag = "failed" }
  If (($item -eq 'MinPasswordLength') -and $DomainPasswordPolicy.MinPasswordLength -le 14) { $flag = "failed" }
  If ($item -eq 'MinPasswordAge') { #-and $DomainPasswordPolicy.MinPasswordAge -lt 1) { $flag = "failed"; $global:o_MinPwdAgeFlag = $false }
    #CREATE A NEW-TIMESPAN '$time1' SET TO '1' DAYS
    $time1 = New-TimeSpan -days 1
    if ($DomainPasswordPolicy.MinPasswordAge.compareto($time1) -eq -1) {
      $flag = "failed"
      $global:o_MinPwdAgeFlag = $false
    }
  }
  If ($item -eq 'MaxPasswordAge') { #-and $DomainPasswordPolicy.MaxPasswordAge -gt 60) { $flag = "failed"; $global:o_MaxPwdAgeFlag = $false }
    #CREATE A NEW-TIMESPAN '$time1' SET TO '60' DAYS
    #SINCE '$DomainPasswordPolicy.MaxPasswordAge' IS ALREADY A TIMESPAN OBJECT WE CAN USE 'TIMESPAN.COMPARETO()' METHOD
    # I honestly don't know why I had to do this! Powershell stopped comparing '$DomainPasswordPolicy.MaxPasswordAge' to '60' properly despite this seemingly still working for '$DomainPasswordPolicy.MinPasswordAge'!
    $time1 = New-TimeSpan -days 60
    if ($DomainPasswordPolicy.MaxPasswordAge.compareto($time1) -gt 0) {
      $flag = "failed"
      $global:o_MaxPwdAgeFlag = $false
    }
  }
  If (($item -eq 'PasswordHistoryCount') -and $DomainPasswordPolicy.PasswordHistoryCount -le '24') { $flag = "failed" }
  If (($item -eq 'ReversibleEncryptionEnabled') -and $DomainPasswordPolicy.ReversibleEncryptionEnabled -eq 'True') { $flag = "failed" }
  If (($item -eq 'LockoutThreshold') -and ($DomainPasswordPolicy.LockoutThreshold -gt 10 -or $DomainPasswordPolicy.LockoutThreshold -eq 0)) { $flag = "failed" }
  If (($item -eq 'LockoutDuration') -and $DomainPasswordPolicy.LockoutDuration -lt 15) { $flag = "failed"; $global:o_LockDurationFlag = $false }
  If (($item -eq 'LockoutObservationWindow') -and $DomainPasswordPolicy.LockoutObservationWindow -le 15) { $flag = "failed"; $global:o_LockObserveFlag = $false }

  $Pwdpolyrow += "<tr>
  <td class=bold_class>$item</td>
  <td class=$flag width='40%' style= 'text-align: center'>$($DomainPasswordPolicy.$item)</td>
  </tr>"
}
Add-Content $HealthReport $Pwdpolyrow
Add-Content $HealthReport "</table></Div>" #End Sub Container

#---------------------------------------------------------------------------------------------------------------------------------------------
# Tombstone and Backup Information
#---------------------------------------------------------------------------------------------------------------------------------------------
Write-Log -Message "Checking Tombstone and Backup Information........"
# Start Sub Container
$tsbkp = "<Div id=TLBkbsubcontainer><table border=1px>
   <caption><h2><a name='tsbkp'>Tombstone & Partitions Backup</h2></caption>"
Add-Content $HealthReport $tsbkp
$ADRootDSE = get-adrootdse  -Server $DCtoConnect
$ADConfigurationNamingContext = $ADRootDSE.configurationNamingContext
$TombstoneObjectInfo = Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$ADConfigurationNamingContext" `
-Partition "$ADConfigurationNamingContext" -Properties * 
[int]$TombstoneLifetime = $TombstoneObjectInfo.tombstoneLifetime
IF ($TombstoneLifetime -eq 0) { $TombstoneLifetime = 60 }
$tsbkprow += "<tr>
<td class=bold_class>TombstoneLifetime</td>
<td width='30%' style= 'text-align: center'>$TombstoneLifetime</td>
</tr>"
[string[]]$Partitions = (Get-ADRootDSE -Server $DCtoConnect).namingContexts
$contextType = [System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain
$context = new-object System.DirectoryServices.ActiveDirectory.DirectoryContext($contextType,$($domaininfo.DNSRoot))
$domainController = [System.DirectoryServices.ActiveDirectory.DomainController]::findOne($context)
ForEach ($partition in $partitions) {
  $domainControllerMetadata = $domainController.GetReplicationMetadata($partition)
  $dsaSignature = $domainControllerMetadata.Item(�dsaSignature�)
  Write-Log "$partition was backed up $($dsaSignature.LastOriginatingChangeTime.DateTime)"
  $tsbkprow += "<tr>
    <td class=bold_class>Last backup of '$partition'</td>
    <td width='30%' style= 'text-align: center'>$($dsaSignature.LastOriginatingChangeTime.ToShortDateString())</td>
    </tr>"
}
Add-Content $HealthReport $tsbkprow
Add-Content $HealthReport "</table></Div></Div>" # End Sub Container and Container Div

#---------------------------------------------------------------------------------------------------------------------------------------------
# Kerberos delegation Info
#---------------------------------------------------------------------------------------------------------------------------------------------
Write-Log -Message "Checking Kerberos delegation Info........"
# Start Sub Container
$krbtgtdel = "<div id=container><Div id=delegationsubcontainer><table border=1px>
   <caption><h2><a name='krbtgtdel'>Kerberos Delegation (Unconstrained)</h2></caption>
         <thead>
		<th>ObjectClass</th>
		<th>Count</th>
        </thead>"
Add-Content $HealthReport $krbtgtdel
## Identify Accounts with Kerberos Delegation
$KerberosDelegationArray = @()
[array]$KerberosDelegationObjects =  Get-ADObject -filter { (UserAccountControl -BAND 0x0080000) -AND (PrimaryGroupID -ne '516') -AND (PrimaryGroupID -ne '521') } -Server $DCtoConnect -prop Name,ObjectClass,PrimaryGroupID,UserAccountControl,ServicePrincipalName

ForEach ($KerberosDelegationObjectItem in $KerberosDelegationObjects) {
  IF ($KerberosDelegationObjectItem.UserAccountControl -BAND 0x0080000) {
    $KerberosDelegationServices = 'All Services' ; $KerberosType = 'Unconstrained'
  } ELSE {
    $KerberosDelegationServices = 'Specific Services' ; $KerberosType = 'Constrained'
  } 
  $KerberosDelegationObjectItem | Add-Member -MemberType NoteProperty -Name KerberosDelegationServices -Value $KerberosDelegationServices -Force
  [array]$KerberosDelegationArray += $KerberosDelegationObjectItem
}

$Requiredpros = $KerberosDelegationArray | Select Name,ObjectClass
$Groupedresult = $Requiredpros |  Group ObjectClass -AsHashTable
$Groupedresult.Keys | ForEach-Object {
    $objs = ""
    $($Groupedresult.$PSItem.Name) | foreach { $objs = $objs + $_ + "<br>" }
    $krbtgtdelrow += "<tr>
    <td class=bold_class>$($PSItem)</td>
    <td class=failed style= 'text-align: center'><a href='javascript:void(0)' onclick=""Powershellparamater('"+ $objs +"')"">$($Groupedresult.$PSItem.Name.count)</a></td>
    </tr>"
}
Add-Content $HealthReport $krbtgtdelrow
Add-Content $HealthReport "</table></Div>" # End Sub Container 

#---------------------------------------------------------------------------------------------------------------------------------------------
# Scan SYSVOL for Group Policy Preference Passwords
#---------------------------------------------------------------------------------------------------------------------------------------------
Write-Log -Message "Scan SYSVOL for Group Policy Preference Passwords......."
# Start Sub Container
$gpppwd = "<Div id=gpppwdsubcontainer><table border=1px>
          <caption><h2><a name='krbtgtdel'>Scan SYSVOL for Group Policy Preference Passwords</h2></caption>"
Add-Content $HealthReport $gpppwd
[int]$Count = 0
$flag = "passed"
$Passfoundfiles = ""
$domainname = ($domaininfo.DistinguishedName.Replace("DC=","")).replace(",",".")
$DomainSYSVOLShareScan = "\\$domainname\SYSVOL\$domainname\Policies\"
Get-ChildItem $DomainSYSVOLShareScan -Filter *.xml -Recurse |  % {
  If (Select-String -Path $_.FullName -Pattern "Cpassword") {
    $Passfoundfiles += $_.FullName + "</br>" ; $Count += 1; $flag= "failed"
  }
}
$gpppwdrow += "<tr>
<td class=bold_class>Items Found</td>
<td class=$flag style= 'text-align: center'><a href='javascript:void(0)' onclick=""Powershellparamater('"+ $Passfoundfiles +"')"">$Count</a></td>
</tr>"
Add-Content $HealthReport $gpppwdrow
Add-Content $HealthReport "</table></Div></Div>" # End Sub Container and Container Div

#-------------------------------------
# KRBTGT account info
#-------------------------------------
Write-Log -Message "Checking KRBTGT account info........"
$krbtgt = "<div id=container><div id=krbtgtcontainer><table border=1px>
   <caption><h2><a name='krbtgt'>KRBTGT Account Info</h2></caption>
         <thead>
		<th>DistinguishedName</th>
		<th>Enabled</th>
        <th>msds-keyversionnumber</th>
        <th>PasswordLastSet</th>
        <th>Created</th>
        </thead>
	        <tr>"
Add-Content $HealthReport $krbtgt
$DomainKRBTGTAccount = Get-ADUser 'krbtgt' -Server $DCtoConnect -Properties 'msds-keyversionnumber',Created,PasswordLastSet
If ($(New-TimeSpan -Start ($DomainKRBTGTAccount.PasswordLastSet) -End $(Get-Date)).Days -gt 180) {
  $flag = "failed"
} else {
  $flag = "passed"
}
$SelectedPros = @("DistinguishedName","Enabled","msds-keyversionnumber","PasswordLastSet","Created")
$SelectedPros | % {
  $krbtgtrow += "<td class=$flag style= 'text-align: center'>$($DomainKRBTGTAccount.$PSItem)</td>"
}
Add-Content $HealthReport $krbtgtrow
Add-Content $HealthReport "</tr></table></div></div>"

#-----------------------
# Privileged AD Group Report
#-----------------------
Write-Log -Message "Performing Privileged AD Group Report......."
#Start Container and Sub Container Div
$group = "<div id=container><div id=groupsubcontainer><table border=1px>
            <caption><h2>Privileged AD Group Info</h2></caption>
            <thead>
		<th>Privileged Group Name</th>
		<th>Members Count</th>
        </thead>"
Add-Content $HealthReport $group
$ADPrivGroupArray = @(
 'Administrators',
 'Domain Admins',
 'Enterprise Admins',
 'Schema Admins',
 'Account Operators',
 'Server Operators',
 'Group Policy Creator Owners',
 'DNSAdmins',
 'Enterprise Key Admins',
 'Exchange Domain Servers',
 'Exchange Enterprise Servers',
 'Exchange Admins',
 'Organization Management',
 'Exchange Windows Permissions'
)
foreach ($group in $ADPrivGroupArray) {
  try {
    $GrpProps = Get-ADGroupMember -Identity $group -Recursive -Server $DCtoConnect -ErrorAction SilentlyContinue | select SamAccountName,distinguishedName
    $tempobj = ""
    $GrpProps | % {
      $tempobj = $tempobj + $_.SamAccountName +"(" + $_.distinguishedName + ")" + "</br>"
    }
    $grouprow += "<tr>
    <td class=bold_class>$group</td>   
    <td style= 'text-align: center'><a href='javascript:void(0)' onclick=""Powershellparamater('"+ $tempobj +"')"">$($GrpProps.SamAccountName.count)</a></td>
    </tr>"
  } catch {
    $grouprow += "<tr>
    <td class=bold_class>$group</td>   
    <td style= 'text-align: center'>NA</td>
    </tr>"
  }
}
Add-Content $HealthReport $grouprow
Add-Content $HealthReport "</table></Div></div>" #End Container

#---------------------------------------------------------------------------------------------------------------------------------------------
# Script Execution Time
#---------------------------------------------------------------------------------------------------------------------------------------------
$myhost = $env:COMPUTERNAME
$ScriptExecutionRow = "<div id=scriptexecutioncontainer><table>
   <caption><h2><a name='Script Execution Time'>Execution Details</h2></caption>
      <th>Start Time</th>
      <th>Stop Time</th>
		<th>Days</th>
      <th>Hours</th>
      <th>Minutes</th>
      <th>Seconds</th>
      <th>Milliseconds</th>
      <th>Script Executed on</th>
	</th>"
# Stop script execution time calculation
$sw.Stop()
$Days = $sw.Elapsed.Days
$Hours = $sw.Elapsed.Hours
$Minutes = $sw.Elapsed.Minutes
$Seconds = $sw.Elapsed.Seconds
$Milliseconds = $sw.Elapsed.Milliseconds
$ScriptStopTime = (Get-Date).ToString('dd-MM-yyyy hh:mm:ss')
$Elapsed = "<tr>
               <td>$ScrptStartTime</td>
               <td>$ScriptStopTime</td>
               <td>$Days</td>
               <td>$Hours</td>
               <td>$Minutes</td>
               <td>$Seconds</td>
               <td>$Milliseconds</td>
               <td>$myhost</td>
               
            </tr>"
$ScriptExecutionRow += $Elapsed
Add-Content $HealthReport $ScriptExecutionRow
Add-Content $HealthReport "</table></div>"

#OUTPUT
$global:o_Domain = $forestinfo.Name.ToUpper()
$global:o_Notes = $global:o_Notes + "`r`nDOMAIN : " + $global:o_Domain
$global:o_PDC = $domaininfo.PDCEmulator.ToUpper()
$global:o_Notes = $global:o_Notes + "`r`nPDC : " + $global:o_PDC
#PASSWORDS
$global:o_PwdComplex = $DomainPasswordPolicy.ComplexityEnabled
$global:o_Notes = $global:o_Notes + "`r`nPASSWORD COMPLEXITY : " + $global:o_PwdComplex
$global:o_MinPwdLen = $DomainPasswordPolicy.MinPasswordLength
$global:o_Notes = $global:o_Notes + "`r`nMIN PASSWORD LENGTH : " + $global:o_MinPwdLen
$global:o_MinPwdAge = $DomainPasswordPolicy.MinPasswordAge
$global:o_Notes = $global:o_Notes + "`r`nMIN PASSWORD AGE : " + $global:o_MinPwdAgeFlag + " - " + $global:o_MinPwdAge
$global:o_MaxPwdAge = $DomainPasswordPolicy.MaxPasswordAge
$global:o_Notes = $global:o_Notes + "`r`nMAX PASSWORD AGE : " + $global:o_MaxPwdAgeFlag + " - " + $global:o_MaxPwdAge
$global:o_PwdHistory = $DomainPasswordPolicy.PasswordHistoryCount
$global:o_Notes = $global:o_Notes + "`r`nPASSWORD HISTORY COUNT : " + $global:o_PwdHistory
$global:o_RevEncrypt = $DomainPasswordPolicy.ReversibleEncryptionEnabled
$global:o_Notes = $global:o_Notes + "`r`nREVERSIBLE ENCRYPTION : " + $global:o_RevEncrypt
#LOCKOUT
$global:o_LockThreshold = $DomainPasswordPolicy.LockoutThreshold
$global:o_Notes = $global:o_Notes + "`r`nLOCKOUT THRESHOLD : " + $global:o_LockThreshold
$global:o_LockDuration = $DomainPasswordPolicy.LockoutDuration
$global:o_Notes = $global:o_Notes + "`r`nLOCKOUT DURATION : " + $global:o_LockDurationFlag + " - " + $global:o_LockDuration
$global:o_LockObserve = $DomainPasswordPolicy.LockoutObservationWindow
$global:o_Notes = $global:o_Notes + "`r`nLOCKOUT OBSERVATION WINDOW : " + $global:o_LockObserveFlag + " - " + $global:o_LockObserve
#USERS
$global:o_TotalUser = $DomainUsers.Count
$global:o_Notes = $global:o_Notes + "`r`nTOTAL USERS : " + $global:o_TotalUser
$global:o_EnabledUser = $DomainEnabledUsers.Count
$global:o_Notes = $global:o_Notes + "`r`nENABLED USERS : " + $global:o_EnabledUser
$global:o_DisabledUser = $DomainDisabledUsers.Count
$global:o_Notes = $global:o_Notes + "`r`nDISABLED USERS : " + $global:o_DisabledUser
$global:o_InactiveUser = $DomainEnabledInactiveUsers.Count
$global:o_Notes = $global:o_Notes + "`r`nINACTIVE USERS : " + $global:o_InactiveUser
$global:o_PwdNoExpire = $DomainUserPasswordNeverExpiresArray.Count
$global:o_Notes = $global:o_Notes + "`r`nUSERS W/ PASSWORD NEVER EXPIRES : " + $global:o_PwdNoExpire
$global:o_PwdNoRequire = $DomainUserPasswordNotRequiredArray.Count
$global:o_Notes = $global:o_Notes + "`r`nUSERS W/ PASSWORD NOT REQUIRED : " + $global:o_PwdNoRequire
$global:o_RevEncryptUser = $DomainUsersWithReversibleEncryptionPasswordArray.Count
$global:o_Notes = $global:o_Notes + "`r`nUSERS W/ REVERSIBLE ENCRYPTION : " + $global:o_RevEncryptUser
$global:o_SIDHistory = $DomainUsersWithSIDHistoryArray.Count
$global:o_Notes = $global:o_Notes + "`r`nUSERS W/ SID HISTORY : " + $global:o_SIDHistory
$global:o_KerbUser = $DomainKerberosDESUsersArray.Count
$global:o_Notes = $global:o_Notes + "`r`nUSERS W/ KERBEROS DES : " + $global:o_KerbUser
$global:o_KerbPreAuthUser = $DomainUserDoesNotRequirePreAuthArray.Count
$global:o_Notes = $global:o_Notes + "`r`nUSERS W/ KERBEROS PRE-AUTH NOT REQUIRED : " + $global:o_KerbPreAuthUser
#NOTES
write-host $global:o_Notes -ForegroundColor Green
$global:o_Notes = $global:o_Notes.replace("`r`n", "<br>")

#---------------------------------------------------------------------------------------------------------------------------------------------
# Sending Mail
#---------------------------------------------------------------------------------------------------------------------------------------------
if ($SendEmail -eq 'Yes') {
  # Send ADHealthCheck Report
  if (Test-Path $HealthReport) {
    try {
      $body = "Please find AD Health Check report attached."
      #$port = "25"
      Send-MailMessage -Priority High -Attachments $HealthReport -To $emailTo -From $emailFrom -SmtpServer $smtpServer -Body $Body -Subject $emailSubject -Credential $Credentials -UseSsl -Port 587 -ErrorAction Stop
    } catch {       
      Write-Log 'Error in sending AD Health Check Report'
    }
  }
  #Send an ERROR mail if Report is not found 
  if (!(Test-Path $HealthReport)) {
    try {
      $body = "ERROR: NO AD Health Check report"
      $port = "25"
      Send-MailMessage -Priority High -To $emailTo -From $emailFrom -SmtpServer $smtpServer -Body $Body -Subject $emailSubject -Port $port -ErrorAction Stop
    } catch {
      Write-Log 'Unable to send Error mail.'
    }
  }
} else {
  Write-Log "As Send Email is NO so report through mail is not being sent. Please find the report in Script directory."
}