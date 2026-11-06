# truenas-https

`backup-check.yaml` is a one-off Velero Backup of the `homelab-tls-probe` namespace into the `truenas-garage`
BackupStorageLocation, which talks to garage over `https://s3.homelab.sudops.pl`. It is applied with
`oc create -f` (operator approves) and expires by its 24 h TTL.
Check: `oc -n openshift-adp get backup truenas-https-check -o jsonpath='{.status.phase}'` reads `Completed`.
