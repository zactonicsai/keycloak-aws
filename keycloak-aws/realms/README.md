# Realm Files

## The fallback rule

| Situation | What happens |
|---|---|
| `myrealm-realm.json` exists here | It gets imported as-is |
| It doesn't exist | A working default realm is generated instead |

**Either way `terraform apply` succeeds.** It never fails just because a file is missing.

Check which one you got:

```bash
cd environments/dev && terraform output realm_source
```

## Naming

The file must be named `<realm_name>-realm.json`, matching `realm_name` in `terraform.tfvars`.

Default `realm_name = "myrealm"` → file must be `myrealm-realm.json`.

## Getting started

```bash
cp example-realm.json.example myrealm-realm.json
# edit it
cd ../environments/dev && terraform apply
```

## Exporting from a running Keycloak

Admin console → **Realm settings** → **Action** → **Partial export**

Tick **groups and roles** and **clients**. Save as `<realm_name>-realm.json` here.

## Important warnings

- **Import only runs for realms that don't already exist.** Restarting won't overwrite a live realm — your users are safe, but edits to this file won't apply to an existing realm either.
- **Never commit real passwords.** `.gitignore` excludes `*-realm.json` by default for this reason.
- **Validate before applying:** `jq empty myrealm-realm.json`
