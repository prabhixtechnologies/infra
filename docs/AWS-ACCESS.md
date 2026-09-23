# Production AWS access

The facts an agent needs are in `.cursor/rules/aws-prod.mdc`. This file is the load and cleanup procedure. Do not probe IAM, RDS, Secrets Manager, or Parameter Store to relearn them.

## Reach the database

1. If `D:\Projects\KEYS\PrabhixTechnologies.pem` or `D:\Projects\KEYS\MobiStack.pem` exists, SSH to `ec2-user@35.154.59.116` with that key. Confirm the address with one describe of `i-05496f940af0517ae` only when SSH fails.
2. On the server, read `POSTGRES_HOST`, `MOBISTACK_DB_USER`, `MOBISTACK_DB_PASSWORD`, and `MOBISTACK_DB_NAME` from `/opt/prabhix/deploy/.env.prod`. Do not print them.
3. Run the loader there, on the VPC, with `sslmode=require`. The phone file is `MobiStack/catalog/phones.json`. The script is `MobiStack/catalog/load_phones.py`. It inserts brands and devices only. It does not insert spare-part rows. Same size or the same mAh is not a fitment.
4. If neither private key is on disk, stop. The IAM user cannot use Session Manager or EC2 Instance Connect, and RDS is not reachable from this PC.

## Cleanup

Anything created to reach the server comes back out in the same session:

- Terminate helper instances. The only instance that stays is `i-05496f940af0517ae`.
- Delete helper volumes and snapshots. Do not delete `vol-0a3a6e1e4b975ee55` (the server's root disk).
- Delete helper key pairs and security groups.
- Delete local key files and any copy of `.env.prod`.
- Confirm with `describe-volumes --filters Name=status,Values=available` and `describe-snapshots --owner-ids self`. Both should be empty. The Elastic IP `35.154.59.116` stays attached to the server.
