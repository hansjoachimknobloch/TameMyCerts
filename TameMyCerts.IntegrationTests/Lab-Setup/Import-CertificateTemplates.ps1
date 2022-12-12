<#
    .SYNOPSIS
    Imports all required certificate templates into AD and binds them to the test certification authority.
#>

#Requires -Modules ActiveDirectory,ADCSAdministration

[cmdletbinding()]
param (
    [Parameter(Mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [String]
    $ConfigNC = "CN=Configuration,DC=tamemycerts-tests,DC=local"
)

Function Set-EnrollPermission {

    param (
        [Parameter(Mandatory=$True)]
        [String]
        $Path,

        [Parameter(Mandatory=$False)]
        [System.Security.Principal.SecurityIdentifier]
        $SecurityIdentifier = "S-1-5-11"
    )

    $Acl = Get-ACL -Path $Path
    
    $Ace = New-Object -TypeName System.DirectoryServices.ExtendedRightAccessRule -ArgumentList @(
        $SecurityIdentifier
        [System.Security.AccessControl.AccessControlType]::Allow,
        [System.Guid]"0E10C968-78FB-11D2-90D4-00C04F79DC55"
    );

    $Acl.AddAccessRule($Ace) 

    Set-Acl -Path $Path -AclObject $Acl 
}

Function New-TemplateOID {

    Param(
        [Parameter(Mandatory=$True)]
        [String]
        $ConfigNC
    )

    $ForestOid = Get-ADObject `
        -Identity "CN=OID,CN=Public Key Services,CN=Services,$ConfigNC" `
        -Properties msPKI-Cert-Template-OID | Select-Object -ExpandProperty msPKI-Cert-Template-OID

    do {

        $OidSuffix1 = Get-Random -Minimum 1000000  -Maximum 99999999
        $OidSuffix2 = Get-Random -Minimum 10000000 -Maximum 99999999
        $Oid = "$ForestOid.$OidSuffix1.$OidSuffix2"

    } until (-not (Get-OIDObject -Oid $Oid -ConfigNC $ConfigNC))

    Return $Oid
}

Function Get-OIDObject {

    param (
        [Parameter(Mandatory=$True)]
        [String]
        $Oid,

        [Parameter(Mandatory=$True)]
        [String]
        $ConfigNC 
    )

    return Get-ADObject `
        -SearchBase "CN=OID,CN=Public Key Services,CN=Services,$ConfigNC" `
        -Filter {msPKI-Cert-Template-OID -eq $Oid}
}

$BaseDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

$Templates = Get-ChildItem -Path "$BaseDirectory\Tests\*.ldf" | 
    Select-Object -ExpandProperty Name | 
        ForEach-Object -Process { $_.Split(".")[0] }

ForEach ($TemplateName in $Templates) {

    $TemplatePath = "CN=$TemplateName,CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"

    If (Test-Path -Path "AD:$TemplatePath") {continue}

    # Import template from LDIF

    $FilePath = "$BaseDirectory\$TemplateName.ldf"
    [void](& ldifde -i -f $FilePath)

    # Restore OID object

    $TemplateOid = New-TemplateOID -ConfigNC $ConfigNC
    Set-AdObject -Identity $TemplatePath -Replace @{"msPKI-Cert-Template-OID" = $TemplateOid}

    # This is a trick that will restore the msPKI-Enterprise-OID object which is linked to the pKICertificateTemplate object
    [void](& certutil -f -oid $TemplateOid $TemplateName)

    Get-OIDObject -Oid $TemplateOid -ConfigNC $ConfigNC | 
        Set-AdObject -Replace @{DisplayName = $TemplateName}

    # Grant Enroll permissions to everyone
    Set-EnrollPermission -Path "AD:$TemplatePath"
}

[void](& certutil -pulse)
[void](& certutil -pulse -user)

# Give the system some time to execute the AutoEnrollment task
Start-Sleep -Seconds 30

# Publish all imported templates
ForEach ($TemplateName in $Templates) { Add-CATemplate -Name $TemplateName -Force }