function Invoke-CippGraphWebhookRenewal {
    $RenewalDate = (Get-Date).AddDays(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    $Tenants = Get-Tenants -IncludeErrors
    $WebhookTable = Get-CIPPTable -TableName webhookTable

    try {
        $WebhookData = Get-AzDataTableEntity @WebhookTable | Where-Object {
            $null -ne $_.SubscriptionID -and
            $_.SubscriptionID -ne '' -and
            ((Get-Date $_.Expiration) -le (Get-Date).AddHours(2))
        }
    } catch {
        $WebhookData = @()
    }

    if (($WebhookData | Measure-Object).Count -eq 0) {
        return
    }

    Write-LogMessage `
        -API 'Scheduler_RenewGraphSubscriptions' `
        -Tenant 'none' `
        -Message 'Starting Graph Subscription Renewal' `
        -Sev 'Info'

    foreach ($UpdateSub in $WebhookData) {
        $TenantFilter = $UpdateSub.PartitionKey

        try {
            if (
                $Tenants.defaultDomainName -notcontains $TenantFilter -and
                $Tenants.customerId -notcontains $TenantFilter
            ) {
                Write-LogMessage `
                    -API 'Renew_Graph_Subscriptions' `
                    -Message "Removing Subscription Renewal for $($UpdateSub.SubscriptionID) as tenant $TenantFilter is not in the tenant list." `
                    -Sev 'Warning' `
                    -Tenant $TenantFilter

                Remove-CIPPAzDataTableEntity `
                    -Force `
                    @WebhookTable `
                    -Entity $UpdateSub

                continue
            }

            #
            # Aktuellen CIPP-Host ermitteln.
            # Wichtig nach einem Domainwechsel:
            # Nicht den Host aus der alten WebhookNotificationUrl übernehmen.
            #
            $BaseURL = Get-CIPPHostname

            if ([string]::IsNullOrWhiteSpace($BaseURL)) {
                throw 'Current CIPP hostname could not be determined.'
            }

            $BaseURL = $BaseURL.Trim().TrimEnd('/')

            #
            # Get-CIPPHostname kann je nach Kontext ggf. bereits ein Schema
            # enthalten. Für New-CIPPGraphSubscription wird nur der Host benötigt.
            #
            if ($BaseURL -match '^https?://') {
                $BaseURL = ([uri]$BaseURL).Host
            }

            try {
                #
                # Bestehende Subscription verlängern UND bei Bedarf auf die
                # aktuelle CIPP-Domain migrieren.
                #
                if ([string]::IsNullOrWhiteSpace($UpdateSub.WebhookNotificationUrl)) {
                    throw 'WebhookNotificationUrl is empty.'
                }

                $OldNotificationUri = [uri]$UpdateSub.WebhookNotificationUrl

                if ([string]::IsNullOrWhiteSpace($OldNotificationUri.PathAndQuery)) {
                    throw 'Existing WebhookNotificationUrl is invalid.'
                }

                $DesiredNotificationUrl = "https://$BaseURL$($OldNotificationUri.PathAndQuery)"

                $Body = @{
                    expirationDateTime = $RenewalDate
                    notificationUrl    = $DesiredNotificationUrl
                } | ConvertTo-Json

                $null = New-GraphPostRequest `
                    -Uri "https://graph.microsoft.com/beta/subscriptions/$($UpdateSub.SubscriptionID)" `
                    -TenantId $TenantFilter `
                    -Type PATCH `
                    -Body $Body `
                    -Verbose

                #
                # Lokalen webhookTable-Eintrag ebenfalls auf die neue Domain
                # und das neue Ablaufdatum aktualisieren.
                #
                $UpdateSub.Expiration = $RenewalDate
                $UpdateSub.WebhookNotificationUrl = $DesiredNotificationUrl

                $null = Add-AzDataTableEntity `
                    @WebhookTable `
                    -Entity $UpdateSub `
                    -Force

                Write-LogMessage `
                    -API 'Renew_Graph_Subscriptions' `
                    -Message "Renewed Subscription: $($UpdateSub.SubscriptionID). Notification URL: $DesiredNotificationUrl" `
                    -Sev 'Info' `
                    -Tenant $TenantFilter

            } catch {
                #
                # Renewal fehlgeschlagen.
                # Subscription mit AKTUELLER CIPP-Domain neu erstellen.
                #
                if ($UpdateSub.TypeofSubscription) {
                    $TypeofSubscription = "$($UpdateSub.TypeofSubscription)"
                } else {
                    $TypeofSubscription = 'updated'
                }

                $Resource = "$($UpdateSub.Resource)"
                $EventType = "$($UpdateSub.EventType)"

                Write-LogMessage `
                    -API 'Renew_Graph_Subscriptions' `
                    -Message "Recreating: $($UpdateSub.SubscriptionID) as renewal failed. Using current CIPP hostname: $BaseURL" `
                    -Sev 'Info' `
                    -Tenant $TenantFilter

                $CreateResult = New-CIPPGraphSubscription `
                    -TenantFilter $TenantFilter `
                    -TypeofSubscription $TypeofSubscription `
                    -BaseURL $BaseURL `
                    -Resource $Resource `
                    -EventType $EventType `
                    -Headers 'GraphSubscriptionRenewal' `
                    -Recreate

                if ($CreateResult -match 'Created Webhook subscription for') {
                    #
                    # Alten Tabellen-Eintrag erst entfernen, wenn die neue
                    # Graph Subscription erfolgreich angelegt wurde.
                    #
                    Remove-CIPPAzDataTableEntity `
                        -Force `
                        @WebhookTable `
                        -Entity $UpdateSub
                }
            }

        } catch {
            Write-LogMessage `
                -API 'Renew_Graph_Subscriptions' `
                -Message "Failed to renew Webhook Subscription: $($UpdateSub.SubscriptionID). Linenumber: $($_.InvocationInfo.ScriptLineNumber) Error: $($_.Exception.Message)" `
                -Sev 'Error' `
                -Tenant $TenantFilter
        }
    }
}
