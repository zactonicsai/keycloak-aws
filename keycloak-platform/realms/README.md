# Realm Files

Used by **project 03-keycloak**.

## The fallback rule

| Situation | What happens |
|---|---|
| `myrealm-realm.json` exists here | Imported as-is |
| It doesn't exist | A working default realm is generated |

**Either way `terraform apply` succeeds.** It never fails on a missing file.

Check which you got:

```bash
cd ../03-keycloak && terraform output realm_source
```

## Naming

File must be `<realm_name>-realm.json`, matching `realm_name` in `03-keycloak/terraform.tfvars`.

Default `realm_name = "myrealm"` → file must be `myrealm-realm.json`.

## Getting started

```bash
cp example-realm.json.example myrealm-realm.json
# edit it
cd ../03-keycloak && terraform apply
```

## How it reaches the instance

Terraform picks the realm (yours or the default), uploads it to a private **S3 bucket**, and the EC2 instance downloads it at boot using its IAM role.

Why not embed it in the boot script? EC2 `user_data` is capped at 16,384 bytes **after base64 encoding**. A realm with a few hundred users blows past that and AWS rejects the launch template outright. S3 removes the ceiling.

## Warnings

- **Import only runs for realms that don't already exist.** Restarting won't overwrite a live realm — your users are safe, but edits here won't apply to an existing realm either.
- **Never commit real passwords.** `.gitignore` excludes `*-realm.json` for this reason.
- **Validate first:** `jq empty myrealm-realm.json`
