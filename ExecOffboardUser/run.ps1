using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$APIName = $TriggerMetadata.FunctionName
Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Accessed this API" -Sev "Debug"
$Username = $request.body.user
$Tenantfilter = $request.body.tenantfilter
if ($username -eq $null) { exit }
$userid = (New-GraphGetRequest -uri "https://graph.microsoft.com/beta/users/$($username)" -tenantid $Tenantfilter).id

$ConvertTable = Import-Csv Conversiontable.csv | Sort-Object -Property 'guid' -Unique

Write-Host ($request.body | ConvertTo-Json)
$results = switch ($request.body) {

    { $_.RevokeSessions -eq 'true' } { 
        try {
            $GraphRequest = New-GraphPostRequest -uri "https://graph.microsoft.com/beta/users/$($userid)/invalidateAllRefreshTokens" -tenantid $TenantFilter -type POST -body '{}'  -verbose
            "Success. All sessions by this user have been revoked"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Revoked sessions for $($userid)" -Sev "Info"

        }
        catch {
            "Failed. $($_.Exception.Message)" 
        }
    }
    { $_.ResetPass -eq 'true' } { 
        try { 
            $password = -join ('abcdefghkmnrstuvwxyzABCDEFGHKLMNPRSTUVWXYZ23456789$%&*#'.ToCharArray() | Get-Random -Count 12)
            $passwordProfile = @"
                {"passwordProfile": { "forceChangePasswordNextSignIn": true, "password": "$password" }}'
"@ 
            $GraphRequest = New-GraphPostRequest -uri "https://graph.microsoft.com/v1.0/users/$($userid)" -tenantid $TenantFilter -type PATCH -body $passwordProfile  -verbose
            "The new password is $password"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Reset the password for $($username)" -Sev "Info" -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not reset password for $($username)" -Sev "Error" -tenant $TenantFilter

            "Could not reset password for $($username). Error: $($_.Exception.Message)"
        }
    }
    { $_.RemoveGroups -eq 'true' } { 
      (New-GraphPostRequest -uri "https://graph.microsoft.com/beta/users/$($userid)/GetMemberGroups" -tenantid $tenantFilter -type POST -body  '{"securityEnabledOnly": false}').value | ForEach-Object {
            $group = $_
            try { 
                $RemoveRequest = New-GraphPostRequest -uri "https://graph.microsoft.com/beta/groups/$_/members/$($userid)/`$ref" -tenantid $tenantFilter -type DELETE -body '' -Verbose
                $Groupname = (New-GraphGetRequest -uri "https://graph.microsoft.com/beta/groups/$_" -tenantid $tenantFilter).displayName
                "Succesfully removed user from group $Groupname"
                Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Removed groups for $($username)" -Sev "Info"  -tenant $TenantFilter

            }
            catch {
                Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not remove $($username) from group $group" -Sev "Error" -tenant $TenantFilter

                "Could not remove user from group $group"
            }
            
        }
    }

    { $_."HideFromGAL" -eq 'true' } {
        try {
            $HideRequest = New-GraphPostRequest -uri "https://graph.microsoft.com/v1.0/users/$($userid)" -tenantid $tenantFilter -type PATCH -body '{"showInAddressList": false}' -verbose
            "Hidden from address list"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Hid $($username) from address list" -Sev "Info"  -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not hide $($username) from address list" -Sev "Error" -tenant $TenantFilter

            "Could not hide $($username) from address list. Error: $($_.Exception.Message)"
        }
    }
    { $_."DisableSignIn" -eq 'true' } {
        try {
            $DisableUser = New-GraphPostRequest -uri "https://graph.microsoft.com/v1.0/users/$($userid)" -tenantid $TenantFilter -type PATCH -body '{"accountEnabled":false}'  -verbose
            "Disabled user account for $username"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Disabled $($username)" -Sev "Info"  -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not disable sign in for $($username)" -Sev "Error" -tenant $TenantFilter

            "Could not disable $($username). Error: $($_.Exception.Message)"
        }
        
    }
    { $_."ConvertToShared" -eq 'true' } { 
        try {
            $SharedMailbox = New-ExoRequest -tenantid $TenantFilter -cmdlet "Set-mailbox" -cmdParams @{Identity = $userid; type = "Shared" }
            "Converted $($username) to Shared Mailbox"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Converted $($username) to a shared mailbox" -Sev "Info" -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not convert $username to shared mailbox" -Sev "Error" -tenant $TenantFilter
            "Could not convert $($username) to a shared mailbox. Error: $($_.Exception.Message)"
        }
    }
    { $_."OnedriveAccess" -ne "" } { 
        try {
            $UserSharepoint = (New-GraphGetRequest -uri "https://graph.microsoft.com/beta/users/$($userid)/drive" -AsApp $true -tenantid $tenantFilter).weburl -replace "/Documents"
            $GainAccessJson = '{"SecondaryContact":"' + $request.body.OnedriveAccess + '","IsCurrentUserPersonalSiteAdmin":false,"IsDelegatedAdmin":true,"UserPersonalSiteUrl":"' + $UserSharepoint + '"}'
            $uri = "https://login.microsoftonline.com/$($Tenant)/oauth2/token"
            $body = "resource=https://admin.microsoft.com&grant_type=refresh_token&refresh_token=$($ENV:ExchangeRefreshToken)"
            $token = Invoke-RestMethod $uri -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction SilentlyContinue -Method post
            $OwnershipOnedrive = Invoke-RestMethod -ContentType "application/json;charset=UTF-8" -Uri 'https://admin.microsoft.com/admin/api/users/setSecondaryOwner' -Body $GainAccessJson -Method POST -Headers @{
                Authorization            = "Bearer $($token.access_token)";
                "x-ms-client-request-id" = [guid]::NewGuid().ToString();
                "x-ms-client-session-id" = [guid]::NewGuid().ToString()
                'x-ms-correlation-id'    = [guid]::NewGuid()
                'X-Requested-With'       = 'XMLHttpRequest' 
            }
            "Users Onedrive url is $UserSharepoint. Access has been given to $($request.body.onedriveaccess)"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Gave $($Request.body.onedriveaccess) access to $($username) onedrive" -Sev "Info" -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not add new owner to Onedrive $($request.body.AccessAutomap) on $($username)" -Sev "Error" -tenant $TenantFilter

            "Could not add owner to Onedrive for $($username). Error: $($_.Exception.Message)"
        }
    }
    { $_."AccessNoAutomap" -ne "" } { 
        try {
            $permissions = New-ExoRequest -tenantid $TenantFilter -cmdlet "Add-MailboxPermission" -cmdParams @{Identity = $userid; user = $Request.body.AccessNoAutomap; automapping = $false; accessRights = @("FullAccess"); InheritanceType = "all" }
            "added $($Request.body.AccessNoAutomap) to $($username) Shared Mailbox without automapping"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Gave full permissions to $($request.body.AccessNoAutomap) on $($username)" -Sev "Info" -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not add mailbox permissions for $($request.body.AccessAutomap) on $($username)" -Sev "Error" -tenant $TenantFilter

            "Could not add shared mailbox permissions for $($username). Error: $($_.Exception.Message)"
        }
    }
    { $_."AccessAutomap" -ne "" } { 
        try {
            $permissions = New-ExoRequest -tenantid $TenantFilter -cmdlet "Add-MailboxPermission" -cmdParams @{Identity = $userid; user = $Request.body.AccessNoAutomap; automapping = $true; accessRights = @("FullAccess"); InheritanceType = "all" }
            "added $($Request.body.AccessAutomap) to $($username) Shared Mailbox with automapping"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Gave full permissions to $($request.body.AccessAutomap) on $($username)" -Sev "Info" -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not add mailbox permissions for $($request.body.AccessAutomap) on $($username)" -Sev "Error" -tenant $TenantFilter

            "Could not add shared mailbox permissions for $($username). Error: $($_.Exception.Message)"
        }
    }
    
    { $_."OOO" -ne "" } { 
        try {
            $permissions = New-ExoRequest -tenantid $TenantFilter -cmdlet "Set-MailboxAutoReplyConfiguration" -cmdParams @{Identity = $userid; AutoReplyState = "Enabled"; InternalMessage = $_."OOO"; ExternalMessage = $_."OOO" }
            "added Out-of-office to $username"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Set Out-of-office for $($username)" -Sev "Info" -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not add OOO for $($username)" -Sev "Error" -tenant $TenantFilter

            "Could not add out of office message for $($username). Error: $($_.Exception.Message)"
        }
    }
    { $_."forward" -ne "" } { 
        try {
            $permissions = New-ExoRequest -tenantid $TenantFilter -cmdlet "Set-mailbox" -cmdParams @{Identity = $userid; ForwardingAddress = $_.forward ; DeliverToMailboxAndForward = $true }
            "Forwarding all email for $username to $($_.Forward)"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Set Forwarding for $($username) to $($_.Forward)" -Sev "Info" -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not add forwarding for $($username)" -Sev "Error" -tenant $TenantFilter

            "Could not add forwarding for $($username). Error: $($_.Exception.Message)"
        }
    }
    { $_."RemoveLicenses" -eq 'true' } {
        try {
            $CurrentLicenses = (New-GraphGetRequest -uri "https://graph.microsoft.com/beta/users/$($userid)" -tenantid $tenantFilter).assignedlicenses.skuid
            $LicensesToRemove = if ($CurrentLicenses) { ConvertTo-Json @( $CurrentLicenses) } else { "[]" }
            $LicenseBody = '{"addLicenses": [], "removeLicenses": ' + $LicensesToRemove + '}'
            $LicRequest = New-GraphPostRequest -uri "https://graph.microsoft.com/beta/users/$($userid)/assignlicense" -tenantid $tenantFilter -type POST -body $LicenseBody -verbose
            "Removed current licenses: $(($ConvertTable | Where-Object { $_.guid -in $CurrentLicenses }).'Product_Display_Name' -join ',')"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Removed all licenses for $($username)" -Sev "Info" -tenant $TenantFilter
           
        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not remove licenses for $($username)" -Sev "Error" -tenant $TenantFilter

            "Could not remove licenses for $($username). Error: $($_.Exception.Message)"
        }
    }

    { $_."Deleteuser" -eq 'true' } {
        try {
            $DeleteRequest = New-GraphPostRequest -uri "https://graph.microsoft.com/beta/users/$($userid)" -type DELETE -tenant $TenantFilter
            "Deleted the user account"
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Deleted account $($username)" -Sev "Info" -tenant $TenantFilter

        }
        catch {
            Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Could not delete $($username)" -Sev "Error" -tenant $TenantFilter
            "Could not delete $($username). Error: $($_.Exception.Message)"
        }
    }
    
}
$body = [pscustomobject]@{"Results" = @($results) }


# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $Body
    })
