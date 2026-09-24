# Prabhix data model

Every table and column in the three databases, as the Flyway migrations define them.
Identity is V1–V3. oneOps is V1–V9. MobiStack is V1–V5. Partition children of
`audit_logs` and `event_logs` are not repeated. They have the same columns as the parent.
From oneOps V9, a mail column that names an organization, a person, a team, or a file is a uuid with no foreign key. Constraints inside the mail schema stay.

A column that shows up on almost every row means the same thing everywhere:

- `id` is a uuid primary key, generated in the database.
- `version` is the optimistic-lock counter.
- `created_at` and `updated_at` are `timestamptz`.
- `created_by` and `updated_by` are uuids of a person. They are usually not foreign keys.
- `organization_id` is the oneOps tenant. `shop_id` is the MobiStack tenant.
- `deleted_at` set means the row is hidden, not removed.

How the databases relate is in [ARCHITECTURE.md](ARCHITECTURE.md). This file is the columns.

## identity

Database `identity`, role `identity`. This is the only place a password, a session, a passkey, or an OAuth grant is stored. It has no organization and no shop.

10 tables.

### Person

- [users](#identity-public-users)

<a id="identity-public-users"></a>
#### users

The person, independent of any product. password_hash is bcrypt and may be null when the person has only used a magic link or a passkey. platform_admin is a claim the products read. It does not by itself authorize a request.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `email` | citext | yes |  | unique |
| `email_verified_at` | timestamptz |  |  |  |
| `phone` | varchar(32) |  |  |  |
| `phone_verified_at` | timestamptz |  |  |  |
| `password_hash` | varchar(120) |  |  |  |
| `password_changed_at` | timestamptz |  |  |  |
| `full_name` | varchar(160) | yes |  |  |
| `display_name` | varchar(80) |  |  |  |
| `avatar_url` | varchar(500) |  |  |  |
| `job_title` | varchar(120) |  |  |  |
| `timezone` | varchar(64) | yes | 'Asia/Kolkata' |  |
| `locale` | varchar(16) | yes | 'en-IN' |  |
| `status` | varchar(24) | yes | 'ACTIVE' |  |
| `platform_admin` | boolean | yes | false |  |
| `failed_login_attempts` | integer | yes | 0 |  |
| `locked_until` | timestamptz |  |  |  |
| `last_login_at` | timestamptz |  |  |  |
| `last_active_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |
| `deletion_requested_at` | timestamptz |  |  |  |

### Sign-in

- [auth_challenges](#identity-public-auth-challenges)
- [auth_identities](#identity-public-auth-identities)
- [auth_events](#identity-public-auth-events)
- [webauthn_credentials](#identity-public-webauthn-credentials)

<a id="identity-public-auth-challenges"></a>
#### auth_challenges

A one-time code or magic link. The secret is stored as a hash. The row is consumed when the person finishes the step.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `purpose` | varchar(32) | yes |  |  |
| `user_id` | uuid |  |  | FK → users.id ON DELETE CASCADE |
| `destination` | citext | yes |  |  |
| `secret_hash` | varchar(64) | yes |  |  |
| `expires_at` | timestamptz | yes |  |  |
| `consumed_at` | timestamptz |  |  |  |
| `attempts` | integer | yes | 0 |  |
| `max_attempts` | integer | yes | 5 |  |
| `ip_address` | varchar(45) |  |  |  |
| `metadata` | jsonb | yes | '{}' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="identity-public-auth-identities"></a>
#### auth_identities

An external sign-in, such as Google, attached to one person.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `provider` | varchar(32) | yes |  |  |
| `provider_subject` | varchar(255) | yes |  |  |
| `provider_email` | citext |  |  |  |
| `raw_profile` | jsonb | yes | '{}' |  |
| `linked_at` | timestamptz | yes | now() |  |
| `last_login_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="identity-public-auth-events"></a>
#### auth_events

Append-only history of sign-in and account changes. No foreign key to users, so the trail survives account deletion.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `user_id` | uuid |  |  |  |
| `email` | citext |  |  |  |
| `type` | text | yes |  |  |
| `outcome` | text | yes |  |  |
| `client_id` | text |  |  |  |
| `ip_address` | varchar(45) |  |  |  |
| `user_agent` | varchar(500) |  |  |  |
| `actor_user_id` | uuid |  |  |  |
| `details` | jsonb | yes | '{}' |  |
| `occurred_at` | timestamptz | yes | now() |  |

<a id="identity-public-webauthn-credentials"></a>
#### webauthn_credentials

A passkey. The public key and sign counter live here.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `user_id` | uuid | yes |  |  |
| `credential_id` | bytea | yes |  | unique |
| `public_key` | bytea | yes |  |  |
| `signature_count` | bigint | yes | 0 |  |
| `aaguid` | uuid |  |  |  |
| `label` | varchar(120) |  |  |  |
| `transports` | jsonb | yes | '[]' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `last_used_at` | timestamptz |  |  |  |
| `backed_up` | boolean |  |  |  |

### Sessions

- [device_sessions](#identity-public-device-sessions)
- [refresh_tokens](#identity-public-refresh-tokens)

<a id="identity-public-device-sessions"></a>
#### device_sessions

A signed-in device. Refresh tokens belong to a session.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `device_id` | varchar(128) |  |  |  |
| `device_name` | varchar(160) |  |  |  |
| `device_type` | varchar(24) | yes | 'WEB' |  |
| `user_agent` | varchar(500) |  |  |  |
| `ip_address` | varchar(45) |  |  |  |
| `last_seen_at` | timestamptz | yes | now() |  |
| `revoked_at` | timestamptz |  |  |  |
| `revoked_reason` | varchar(64) |  |  |  |
| `cookie_token_hash` | varchar(64) |  |  |  |
| `cookie_expires_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="identity-public-refresh-tokens"></a>
#### refresh_tokens

A rotating refresh token. The raw token is never stored, only its hash.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `session_id` | uuid | yes |  | FK → device_sessions.id ON DELETE CASCADE |
| `token_hash` | varchar(64) | yes |  | unique |
| `expires_at` | timestamptz | yes |  |  |
| `used_at` | timestamptz |  |  |  |
| `revoked_at` | timestamptz |  |  |  |
| `replaced_by` | uuid |  |  | FK → refresh_tokens.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### OAuth

- [oauth2_registered_client](#identity-public-oauth2-registered-client)
- [oauth2_authorization](#identity-public-oauth2-authorization)
- [oauth2_authorization_consent](#identity-public-oauth2-authorization-consent)

<a id="identity-public-oauth2-registered-client"></a>
#### oauth2_registered_client

An OAuth client: the consoles, the mobile apps, and the marketing site.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | varchar(100) | yes |  | primary key |
| `client_id` | varchar(100) | yes |  |  |
| `client_id_issued_at` | timestamptz | yes | CURRENT_TIMESTAMP |  |
| `client_secret` | varchar(200) |  | NULL |  |
| `client_secret_expires_at` | timestamptz |  |  |  |
| `client_name` | varchar(200) | yes |  |  |
| `client_authentication_methods` | varchar(1000) | yes |  |  |
| `authorization_grant_types` | varchar(1000) | yes |  |  |
| `redirect_uris` | varchar(1000) |  | NULL |  |
| `post_logout_redirect_uris` | varchar(1000) |  | NULL |  |
| `scopes` | varchar(1000) | yes |  |  |
| `client_settings` | varchar(2000) | yes |  |  |
| `token_settings` | varchar(2000) | yes |  |  |

<a id="identity-public-oauth2-authorization"></a>
#### oauth2_authorization

Spring Authorization Server's in-flight and granted authorizations.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | varchar(100) | yes |  | primary key |
| `registered_client_id` | varchar(100) | yes |  |  |
| `principal_name` | varchar(200) | yes |  |  |
| `authorization_grant_type` | varchar(100) | yes |  |  |
| `authorized_scopes` | varchar(1000) |  | NULL |  |
| `attributes` | text |  |  |  |
| `state` | varchar(500) |  | NULL |  |
| `authorization_code_value` | text |  |  |  |
| `authorization_code_issued_at` | timestamptz |  |  |  |
| `authorization_code_expires_at` | timestamptz |  |  |  |
| `authorization_code_metadata` | text |  |  |  |
| `access_token_value` | text |  |  |  |
| `access_token_issued_at` | timestamptz |  |  |  |
| `access_token_expires_at` | timestamptz |  |  |  |
| `access_token_metadata` | text |  |  |  |
| `access_token_type` | varchar(100) |  | NULL |  |
| `access_token_scopes` | varchar(1000) |  | NULL |  |
| `oidc_id_token_value` | text |  |  |  |
| `oidc_id_token_issued_at` | timestamptz |  |  |  |
| `oidc_id_token_expires_at` | timestamptz |  |  |  |
| `oidc_id_token_metadata` | text |  |  |  |
| `refresh_token_value` | text |  |  |  |
| `refresh_token_issued_at` | timestamptz |  |  |  |
| `refresh_token_expires_at` | timestamptz |  |  |  |
| `refresh_token_metadata` | text |  |  |  |
| `user_code_value` | text |  |  |  |
| `user_code_issued_at` | timestamptz |  |  |  |
| `user_code_expires_at` | timestamptz |  |  |  |
| `user_code_metadata` | text |  |  |  |
| `device_code_value` | text |  |  |  |
| `device_code_issued_at` | timestamptz |  |  |  |
| `device_code_expires_at` | timestamptz |  |  |  |
| `device_code_metadata` | text |  |  |  |

<a id="identity-public-oauth2-authorization-consent"></a>
#### oauth2_authorization_consent

The scopes a person has approved for a client.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `registered_client_id` | varchar(100) | yes |  |  |
| `principal_name` | varchar(200) | yes |  |  |
| `authorities` | varchar(1000) | yes |  |  |

## oneops

Database `oneops`, role `oneops`. One schema `public` for the product, and schema `mail` for the mailbox and helpdesk tables. Money in this database is integer paise. The tenant column is `organization_id`, except the marketing-site tables, which belong to Prabhix itself.

93 tables.

### People

- [users](#oneops-public-users)

<a id="oneops-public-users"></a>
#### users

oneOps' mirror of a person. The id matches Identity. There is no password column. platform_admin is granted here, not copied from Identity. The default organization is the one the console opens.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `email` | citext | yes |  | unique |
| `email_verified_at` | timestamptz |  |  |  |
| `full_name` | varchar(160) | yes |  |  |
| `display_name` | varchar(80) |  |  |  |
| `avatar_url` | varchar(500) |  |  |  |
| `job_title` | varchar(120) |  |  |  |
| `timezone` | varchar(64) | yes | 'Asia/Kolkata' |  |
| `locale` | varchar(16) | yes | 'en-IN' |  |
| `status` | varchar(24) | yes | 'ACTIVE' |  |
| `platform_admin` | boolean | yes | false |  |
| `last_active_at` | timestamptz |  |  |  |
| `default_organization_id` | uuid |  |  | FK → organizations.id ON DELETE SET NULL |
| `notification_prefs` | jsonb | yes | '{}' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

### Organization

- [api_keys](#oneops-public-api-keys)
- [invitations](#oneops-public-invitations)
- [organization_domains](#oneops-public-organization-domains)
- [organization_memberships](#oneops-public-organization-memberships)
- [organizations](#oneops-public-organizations)
- [permissions](#oneops-public-permissions)
- [role_permissions](#oneops-public-role-permissions)
- [roles](#oneops-public-roles)
- [team_members](#oneops-public-team-members)
- [teams](#oneops-public-teams)

<a id="oneops-public-api-keys"></a>
#### api_keys

A machine credential for one organization. The secret is stored as a hash.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `name` | varchar(120) | yes |  |  |
| `key_prefix` | varchar(16) | yes |  |  |
| `key_hash` | varchar(64) | yes |  | unique |
| `scopes` | jsonb | yes | '[]' |  |
| `created_by_user` | uuid | yes |  | FK → users.id ON DELETE RESTRICT |
| `last_used_at` | timestamptz |  |  |  |
| `expires_at` | timestamptz |  |  |  |
| `revoked_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-invitations"></a>
#### invitations

An invitation to join an organization, before the person has accepted.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `email` | citext | yes |  |  |
| `role_id` | uuid | yes |  | FK → roles.id ON DELETE RESTRICT |
| `team_id` | uuid |  |  | FK → teams.id ON DELETE SET NULL |
| `token_hash` | varchar(64) | yes |  | unique |
| `status` | varchar(24) | yes | 'PENDING' |  |
| `message` | varchar(1000) |  |  |  |
| `expires_at` | timestamptz | yes |  |  |
| `accepted_at` | timestamptz |  |  |  |
| `accepted_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `revoked_at` | timestamptz |  |  |  |
| `invited_by` | uuid | yes |  | FK → users.id ON DELETE RESTRICT |
| `reminder_count` | integer | yes | 0 |  |
| `last_sent_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-organization-domains"></a>
#### organization_domains

A domain an organization claims, and whether it has been verified.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes |  | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `domain` | citext | yes |  |  |
| `verification_token` | varchar(64) | yes |  |  |
| `verified_at` | timestamptz |  |  |  |
| `last_checked_at` | timestamptz |  |  |  |
| `last_check_error` | text |  |  |  |
| `auto_join_enabled` | boolean | yes | false |  |
| `auto_join_role_id` | uuid |  |  | FK → roles.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-public-organization-memberships"></a>
#### organization_memberships

A person's membership in one organization, including the role they hold there.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `role_id` | uuid | yes |  | FK → roles.id ON DELETE RESTRICT |
| `status` | varchar(24) | yes | 'ACTIVE' |  |
| `display_name` | varchar(160) | yes |  |  |
| `email` | citext | yes |  |  |
| `employee_id` | varchar(64) |  |  |  |
| `department` | varchar(120) |  |  |  |
| `joined_at` | timestamptz | yes | now() |  |
| `invited_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `last_active_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-organizations"></a>
#### organizations

A tenant of oneOps. Almost every other oneOps row points here.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `name` | varchar(200) | yes |  |  |
| `slug` | varchar(80) | yes |  | unique |
| `legal_name` | varchar(250) |  |  |  |
| `gstin` | varchar(15) |  |  |  |
| `pan` | varchar(10) |  |  |  |
| `billing_email` | citext |  |  |  |
| `billing_address` | jsonb | yes | '{}' |  |
| `phone` | varchar(32) |  |  |  |
| `website` | varchar(255) |  |  |  |
| `logo_url` | varchar(500) |  |  |  |
| `timezone` | varchar(64) | yes | 'Asia/Kolkata' |  |
| `locale` | varchar(16) | yes | 'en-IN' |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `status` | varchar(24) | yes | 'TRIAL' |  |
| `trial_ends_at` | timestamptz |  |  |  |
| `member_count` | integer | yes | 0 |  |
| `seat_limit` | integer | yes | 5 |  |
| `settings` | jsonb | yes | '{}' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |
| `purge_scheduled_at` | timestamptz |  |  |  |

<a id="oneops-public-permissions"></a>
#### permissions

The catalog of permission codes. Code checks these strings, not role names.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `code` | varchar(64) | yes |  | primary key |
| `category` | varchar(32) | yes |  |  |
| `description` | varchar(255) | yes |  |  |
| `assignable` | boolean | yes | true |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="oneops-public-role-permissions"></a>
#### role_permissions

Which permissions a role includes.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `role_id` | uuid | yes |  | FK → roles.id ON DELETE CASCADE |
| `permission_code` | varchar(64) | yes |  | FK → permissions.code ON DELETE CASCADE |
| `created_at` | timestamptz | yes | now() |  |

<a id="oneops-public-roles"></a>
#### roles

A bundle of permissions. System roles have a null organization and are shared. Custom roles belong to one organization.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid |  |  | FK → organizations.id ON DELETE CASCADE |
| `role_key` | varchar(64) | yes |  |  |
| `name` | varchar(80) | yes |  |  |
| `description` | varchar(255) |  |  |  |
| `is_system` | boolean | yes | false |  |
| `rank` | integer | yes | 100 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-team-members"></a>
#### team_members

A person on a team.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `team_id` | uuid | yes |  | FK → teams.id ON DELETE CASCADE |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `team_role` | varchar(24) | yes | 'MEMBER' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-teams"></a>
#### teams

A group of people inside one organization, used for mail assignment and visibility.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `slug` | varchar(80) | yes |  |  |
| `name` | varchar(120) | yes |  |  |
| `description` | varchar(500) |  |  |  |
| `lead_user_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `member_count` | integer | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Platform staff

- [platform_staff_roles](#oneops-public-platform-staff-roles)

<a id="oneops-public-platform-staff-roles"></a>
#### platform_staff_roles

A Prabhix staff grant: who, which staff role, who granted it, and whether it was revoked.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes |  | primary key |
| `version` | bigint | yes | 0 |  |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `role` | varchar(24) | yes |  |  |
| `granted_at` | timestamptz | yes | now() |  |
| `granted_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `revoked_at` | timestamptz |  |  |  |
| `revoked_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `note` | text |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Files

- [stored_files](#oneops-public-stored-files)

<a id="oneops-public-stored-files"></a>
#### stored_files

Metadata for an object in S3. The bytes are not in Postgres. purpose says what the file is for.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `storage_key` | varchar(500) | yes |  |  |
| `bucket` | varchar(120) | yes |  |  |
| `original_filename` | varchar(255) | yes |  |  |
| `content_type` | varchar(160) | yes |  |  |
| `size_bytes` | bigint | yes |  |  |
| `purpose` | varchar(32) | yes |  |  |
| `uploaded_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `scan_status` | varchar(16) | yes | 'PENDING' |  |
| `scanned_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

### Mail

- [mail.mail_aliases](#oneops-mail-mail-aliases)
- [mail.mail_attachments](#oneops-mail-mail-attachments)
- [mail.mail_canned_replies](#oneops-mail-mail-canned-replies)
- [mail.mail_delivery_events](#oneops-mail-mail-delivery-events)
- [mail.mail_domains](#oneops-mail-mail-domains)
- [mail.mail_folders](#oneops-mail-mail-folders)
- [mail.mail_inbound_raw](#oneops-mail-mail-inbound-raw)
- [mail.mail_mailbox_members](#oneops-mail-mail-mailbox-members)
- [mail.mail_mailboxes](#oneops-mail-mail-mailboxes)
- [mail.mail_messages](#oneops-mail-mail-messages)
- [mail.mail_outbox](#oneops-mail-mail-outbox)
- [mail.mail_routing_rules](#oneops-mail-mail-routing-rules)
- [mail.mail_suppressions](#oneops-mail-mail-suppressions)
- [mail.mail_tags](#oneops-mail-mail-tags)
- [mail.mail_templates](#oneops-mail-mail-templates)
- [mail.mail_thread_ai_suggestions](#oneops-mail-mail-thread-ai-suggestions)
- [mail.mail_thread_drafts](#oneops-mail-mail-thread-drafts)
- [mail.mail_thread_events](#oneops-mail-mail-thread-events)
- [mail.mail_thread_flags](#oneops-mail-mail-thread-flags)
- [mail.mail_thread_folders](#oneops-mail-mail-thread-folders)
- [mail.mail_thread_notes](#oneops-mail-mail-thread-notes)
- [mail.mail_thread_tags](#oneops-mail-mail-thread-tags)
- [mail.mail_threads](#oneops-mail-mail-threads)
- [mail.mail_webhook_events](#oneops-mail-mail-webhook-events)

<a id="oneops-mail-mail-aliases"></a>
#### mail.mail_aliases

An extra address that delivers into a mailbox.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `mailbox_id` | uuid | yes |  | FK → mail_mailboxes.id ON DELETE CASCADE |
| `address` | citext | yes |  | unique |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-attachments"></a>
#### mail.mail_attachments

A file attached to a mail message, pointing at stored_files.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `message_id` | uuid | yes |  | FK → mail_messages.id ON DELETE CASCADE |
| `file_id` | uuid | yes |  | uuid, no foreign key |
| `filename` | varchar(255) | yes |  |  |
| `content_type` | varchar(160) | yes |  |  |
| `size_bytes` | bigint | yes |  |  |
| `is_inline` | boolean | yes | false |  |
| `content_id` | varchar(255) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-canned-replies"></a>
#### mail.mail_canned_replies

A saved reply for the helpdesk.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `mailbox_id` | uuid |  |  | FK → mail_mailboxes.id ON DELETE CASCADE |
| `shortcut` | varchar(60) |  |  |  |
| `title` | varchar(200) | yes |  |  |
| `subject` | varchar(500) |  |  |  |
| `body_html` | text | yes |  |  |
| `body_text` | text |  |  |  |
| `variables` | jsonb | yes | '[]' |  |
| `usage_count` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-mail-mail-delivery-events"></a>
#### mail.mail_delivery_events

A bounce, complaint, or delivery notice for an outbound message.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `organization_id` | uuid |  |  | uuid, no foreign key |
| `outbox_id` | uuid |  |  | FK → mail_outbox.id ON DELETE CASCADE |
| `message_id` | uuid |  |  | FK → mail_messages.id ON DELETE CASCADE |
| `address` | citext | yes |  |  |
| `event_type` | varchar(24) | yes |  |  |
| `provider_code` | varchar(32) |  |  |  |
| `detail` | varchar(1000) |  |  |  |
| `clicked_url` | varchar(2000) |  |  |  |
| `user_agent` | varchar(500) |  |  |  |
| `ip_address` | varchar(45) |  |  |  |
| `occurred_at` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="oneops-mail-mail-domains"></a>
#### mail.mail_domains

A domain the platform sends or receives for, and its DNS verification state.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `domain` | citext | yes |  | unique |
| `status` | varchar(24) | yes | 'PENDING' |  |
| `mode` | varchar(24) | yes | 'EXTERNAL_IMAP' |  |
| `verification_token` | varchar(80) | yes |  |  |
| `dkim_selector` | varchar(63) | yes | 'pbx1' |  |
| `dkim_public_key` | text |  |  |  |
| `dkim_private_key_enc` | text |  |  |  |
| `mx_verified_at` | timestamptz |  |  |  |
| `spf_verified_at` | timestamptz |  |  |  |
| `dkim_verified_at` | timestamptz |  |  |  |
| `dmarc_verified_at` | timestamptz |  |  |  |
| `ownership_verified_at` | timestamptz |  |  |  |
| `last_checked_at` | timestamptz |  |  |  |
| `dns_report` | jsonb | yes | '{}' |  |
| `is_default` | boolean | yes | false |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-mail-mail-folders"></a>
#### mail.mail_folders

A folder in a mailbox, such as Inbox or a custom folder.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `mailbox_id` | uuid | yes |  | FK → mail_mailboxes.id ON DELETE CASCADE |
| `kind` | varchar(16) | yes | 'CUSTOM' |  |
| `name` | varchar(120) | yes |  |  |
| `parent_id` | uuid |  |  | FK → mail_folders.id ON DELETE CASCADE |
| `sort_order` | integer | yes | 100 |  |
| `colour` | varchar(9) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-mail-mail-inbound-raw"></a>
#### mail.mail_inbound_raw

The raw MIME of an inbound message, kept so parsing can be retried.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `mailbox_id` | uuid | yes |  | FK → mail_mailboxes.id ON DELETE CASCADE |
| `source` | varchar(16) | yes |  |  |
| `source_uid` | bigint |  |  |  |
| `message_id_header` | varchar(998) |  |  |  |
| `raw_file_id` | uuid |  |  | uuid, no foreign key |
| `raw_content` | text |  |  |  |
| `size_bytes` | integer |  |  |  |
| `status` | varchar(24) | yes | 'PENDING' |  |
| `attempts` | integer | yes | 0 |  |
| `last_error` | varchar(2000) |  |  |  |
| `resulting_message_id` | uuid |  |  | FK → mail_messages.id ON DELETE SET NULL |
| `received_at` | timestamptz | yes | now() |  |
| `processed_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-mailbox-members"></a>
#### mail.mail_mailbox_members

Who can open a mailbox, and at what access level.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `mailbox_id` | uuid | yes |  | FK → mail_mailboxes.id ON DELETE CASCADE |
| `user_id` | uuid |  |  | uuid, no foreign key |
| `team_id` | uuid |  |  | uuid, no foreign key |
| `access_level` | varchar(16) | yes | 'MEMBER' |  |
| `notify` | boolean | yes | true |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-mailboxes"></a>
#### mail.mail_mailboxes

An address. SHARED is a queue. PERSONAL is one person's mail and must name an owner. password_hash is the IMAP secret, not the account password.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `mail_domain_id` | uuid |  |  | FK → mail_domains.id ON DELETE SET NULL |
| `address` | citext | yes |  | unique |
| `name` | varchar(120) | yes |  |  |
| `description` | varchar(500) |  |  |  |
| `kind` | varchar(16) | yes | 'SHARED' |  |
| `status` | varchar(16) | yes | 'ACTIVE' |  |
| `colour` | varchar(9) |  |  |  |
| `signature_html` | text |  |  |  |
| `reply_to` | citext |  |  |  |
| `imap_host` | varchar(255) |  |  |  |
| `imap_port` | integer |  |  |  |
| `imap_username` | varchar(255) |  |  |  |
| `imap_password_enc` | text |  |  |  |
| `imap_use_ssl` | boolean | yes | true |  |
| `imap_folder` | varchar(255) | yes | 'INBOX' |  |
| `imap_last_uid` | bigint | yes | 0 |  |
| `imap_uid_validity` | bigint |  |  |  |
| `imap_last_polled_at` | timestamptz |  |  |  |
| `imap_last_error` | varchar(500) |  |  |  |
| `imap_consecutive_errors` | integer | yes | 0 |  |
| `smtp_host` | varchar(255) |  |  |  |
| `smtp_port` | integer |  |  |  |
| `smtp_username` | varchar(255) |  |  |  |
| `smtp_password_enc` | text |  |  |  |
| `auto_reply_enabled` | boolean | yes | false |  |
| `auto_reply_subject` | varchar(255) |  |  |  |
| `auto_reply_body_html` | text |  |  |  |
| `sla_first_response_mins` | integer |  |  |  |
| `sla_resolution_mins` | integer |  |  |  |
| `business_hours` | jsonb | yes | '{}' |  |
| `timezone` | varchar(64) | yes | 'Asia/Kolkata' |  |
| `open_thread_count` | integer | yes | 0 |  |
| `unassigned_count` | integer | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |
| `password_hash` | text |  |  |  |
| `password_updated_at` | timestamptz |  |  |  |
| `owner_user_id` | uuid |  |  | uuid, no foreign key |

<a id="oneops-mail-mail-messages"></a>
#### mail.mail_messages

One MIME message on a thread.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `thread_id` | uuid | yes |  | FK → mail_threads.id ON DELETE CASCADE |
| `mailbox_id` | uuid | yes |  | FK → mail_mailboxes.id ON DELETE CASCADE |
| `direction` | varchar(16) | yes |  |  |
| `message_id_header` | varchar(998) |  |  |  |
| `in_reply_to` | varchar(998) |  |  |  |
| `references_header` | text |  |  |  |
| `from_address` | citext | yes |  |  |
| `from_name` | varchar(200) |  |  |  |
| `to_addresses` | jsonb | yes | '[]' |  |
| `cc_addresses` | jsonb | yes | '[]' |  |
| `bcc_addresses` | jsonb | yes | '[]' |  |
| `reply_to_address` | citext |  |  |  |
| `subject` | varchar(500) |  |  |  |
| `body_text` | text |  |  |  |
| `body_html` | text |  |  |  |
| `snippet` | varchar(320) |  |  |  |
| `headers` | jsonb | yes | '{}' |  |
| `raw_file_id` | uuid |  |  | uuid, no foreign key |
| `size_bytes` | integer |  |  |  |
| `attachment_count` | integer | yes | 0 |  |
| `delivery_status` | varchar(16) | yes | 'RECEIVED' |  |
| `delivery_error` | varchar(1000) |  |  |  |
| `spam_score` | numeric(5,2) |  |  |  |
| `spf_result` | varchar(16) |  |  |  |
| `dkim_result` | varchar(16) |  |  |  |
| `dmarc_result` | varchar(16) |  |  |  |
| `sent_by_user_id` | uuid |  |  | uuid, no foreign key |
| `occurred_at` | timestamptz | yes | now() |  |
| `read_at` | timestamptz |  |  |  |
| `search_vector` | tsvector |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-mail-mail-outbox"></a>
#### mail.mail_outbox

A rendered message waiting for SMTP, with retries.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid |  |  | uuid, no foreign key |
| `mailbox_id` | uuid |  |  | FK → mail_mailboxes.id ON DELETE SET NULL |
| `thread_id` | uuid |  |  | FK → mail_threads.id ON DELETE CASCADE |
| `message_id` | uuid |  |  | FK → mail_messages.id ON DELETE SET NULL |
| `template_key` | varchar(80) |  |  |  |
| `locale` | varchar(16) | yes | 'en' |  |
| `template_variables` | jsonb | yes | '{}' |  |
| `from_address` | citext | yes |  |  |
| `from_name` | varchar(200) |  |  |  |
| `reply_to` | citext |  |  |  |
| `to_addresses` | jsonb | yes | '[]' |  |
| `cc_addresses` | jsonb | yes | '[]' |  |
| `bcc_addresses` | jsonb | yes | '[]' |  |
| `subject` | varchar(500) |  |  |  |
| `body_html` | text |  |  |  |
| `body_text` | text |  |  |  |
| `headers` | jsonb | yes | '{}' |  |
| `attachment_ids` | jsonb | yes | '[]' |  |
| `dedupe_key` | varchar(200) |  |  |  |
| `priority` | integer | yes | 50 |  |
| `status` | varchar(16) | yes | 'PENDING' |  |
| `attempts` | integer | yes | 0 |  |
| `max_attempts` | integer | yes | 6 |  |
| `scheduled_at` | timestamptz | yes | now() |  |
| `next_attempt_at` | timestamptz |  |  |  |
| `claimed_at` | timestamptz |  |  |  |
| `claimed_by` | varchar(80) |  |  |  |
| `sent_at` | timestamptz |  |  |  |
| `last_error` | varchar(2000) |  |  |  |
| `transport_used` | varchar(32) |  |  |  |
| `provider_message_id` | varchar(255) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-routing-rules"></a>
#### mail.mail_routing_rules

How an inbound message is assigned: conditions and actions stored as jsonb.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `mailbox_id` | uuid |  |  | FK → mail_mailboxes.id ON DELETE CASCADE |
| `name` | varchar(160) | yes |  |  |
| `description` | varchar(500) |  |  |  |
| `enabled` | boolean | yes | true |  |
| `priority` | integer | yes | 100 |  |
| `match_mode` | varchar(8) | yes | 'ALL' |  |
| `conditions` | jsonb | yes | '[]' |  |
| `actions` | jsonb | yes | '[]' |  |
| `continue_after_match` | boolean | yes | false |  |
| `match_count` | bigint | yes | 0 |  |
| `last_matched_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-suppressions"></a>
#### mail.mail_suppressions

An address that must not be mailed, after a bounce or a complaint.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid |  |  | uuid, no foreign key |
| `address` | citext | yes |  |  |
| `reason` | varchar(24) | yes |  |  |
| `detail` | varchar(1000) |  |  |  |
| `expires_at` | timestamptz |  |  |  |
| `bounce_count` | integer | yes | 1 |  |
| `last_bounce_at` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-tags"></a>
#### mail.mail_tags

A label an organization applies to threads.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `slug` | varchar(60) | yes |  |  |
| `name` | varchar(60) | yes |  |  |
| `colour` | varchar(9) | yes | '#0e7490' |  |
| `description` | varchar(255) |  |  |  |
| `usage_count` | integer | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-templates"></a>
#### mail.mail_templates

A transactional template. organization_id null means the platform default.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid |  |  | uuid, no foreign key |
| `template_key` | varchar(80) | yes |  |  |
| `locale` | varchar(16) | yes | 'en' |  |
| `name` | varchar(160) | yes |  |  |
| `description` | varchar(500) |  |  |  |
| `subject` | varchar(500) | yes |  |  |
| `body_html` | text | yes |  |  |
| `body_text` | text |  |  |  |
| `variables` | jsonb | yes | '[]' |  |
| `category` | varchar(24) | yes | 'TRANSACTIONAL' |  |
| `tracking_enabled` | boolean | yes | false |  |
| `enabled` | boolean | yes | true |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-thread-ai-suggestions"></a>
#### mail.mail_thread_ai_suggestions

A suggested reply or tags for a thread, produced by the AI module.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `thread_id` | uuid | yes |  | unique; FK → mail_threads.id ON DELETE CASCADE |
| `suggested_tags` | jsonb | yes | '[]' |  |
| `suggested_priority` | varchar(16) |  |  |  |
| `intent` | varchar(500) |  |  |  |
| `confidence` | numeric(4,3) |  |  |  |
| `provider` | varchar(32) |  |  |  |
| `model` | varchar(80) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-mail-mail-thread-drafts"></a>
#### mail.mail_thread_drafts

An unsent reply being composed on a thread.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `thread_id` | uuid |  |  | FK → mail_threads.id ON DELETE CASCADE |
| `author_user_id` | uuid | yes |  | uuid, no foreign key |
| `reply_mode` | varchar(16) | yes | 'REPLY' |  |
| `to_addresses` | jsonb | yes | '[]' |  |
| `cc_addresses` | jsonb | yes | '[]' |  |
| `bcc_addresses` | jsonb | yes | '[]' |  |
| `subject` | varchar(500) |  |  |  |
| `body_html` | text |  |  |  |
| `attachment_ids` | jsonb | yes | '[]' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `mailbox_id` | uuid |  |  | FK → mail_mailboxes.id ON DELETE CASCADE |

<a id="oneops-mail-mail-thread-events"></a>
#### mail.mail_thread_events

Something that happened on a thread: assigned, snoozed, status changed.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `thread_id` | uuid | yes |  | FK → mail_threads.id ON DELETE CASCADE |
| `event_type` | varchar(32) | yes |  |  |
| `actor_user_id` | uuid |  |  | uuid, no foreign key |
| `actor_label` | varchar(160) |  |  |  |
| `from_value` | varchar(255) |  |  |  |
| `to_value` | varchar(255) |  |  |  |
| `metadata` | jsonb | yes | '{}' |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="oneops-mail-mail-thread-flags"></a>
#### mail.mail_thread_flags

Per-reader state on a thread, such as read or starred.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `thread_id` | uuid | yes |  | FK → mail_threads.id ON DELETE CASCADE |
| `user_id` | uuid | yes |  | uuid, no foreign key |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `read_at` | timestamptz |  |  |  |
| `starred_at` | timestamptz |  |  |  |
| `snoozed_until` | timestamptz |  |  |  |
| `updated_at` | timestamptz | yes | now() |  |

<a id="oneops-mail-mail-thread-folders"></a>
#### mail.mail_thread_folders

Which folder a thread is filed in.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `thread_id` | uuid | yes |  | primary key; FK → mail_threads.id ON DELETE CASCADE |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `folder_id` | uuid | yes |  | FK → mail_folders.id ON DELETE CASCADE |
| `moved_at` | timestamptz | yes | now() |  |
| `moved_by` | uuid |  |  | uuid, no foreign key |

<a id="oneops-mail-mail-thread-notes"></a>
#### mail.mail_thread_notes

An internal note on a thread, not sent to the customer.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `thread_id` | uuid | yes |  | FK → mail_threads.id ON DELETE CASCADE |
| `author_user_id` | uuid | yes |  | uuid, no foreign key |
| `body_html` | text | yes |  |  |
| `body_text` | text |  |  |  |
| `mentioned_users` | jsonb | yes | '[]' |  |
| `edited_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-mail-mail-thread-tags"></a>
#### mail.mail_thread_tags

A tag applied to a thread.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `thread_id` | uuid | yes |  | FK → mail_threads.id ON DELETE CASCADE |
| `tag_id` | uuid | yes |  | FK → mail_tags.id ON DELETE CASCADE |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `applied_by` | uuid |  |  | uuid, no foreign key |
| `created_at` | timestamptz | yes | now() |  |

<a id="oneops-mail-mail-threads"></a>
#### mail.mail_threads

A conversation in a mailbox: assignee, status, SLA, and the customer address.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | uuid, no foreign key |
| `mailbox_id` | uuid | yes |  | FK → mail_mailboxes.id ON DELETE CASCADE |
| `reference_key` | varchar(24) | yes |  | unique |
| `subject` | varchar(500) | yes |  |  |
| `normalized_subject` | varchar(500) | yes |  |  |
| `status` | varchar(24) | yes | 'OPEN' |  |
| `priority` | varchar(16) | yes | 'NORMAL' |  |
| `assignee_user_id` | uuid |  |  | uuid, no foreign key |
| `assignee_team_id` | uuid |  |  | uuid, no foreign key |
| `assigned_at` | timestamptz |  |  |  |
| `assigned_by` | uuid |  |  | uuid, no foreign key |
| `customer_email` | citext |  |  |  |
| `customer_name` | varchar(200) |  |  |  |
| `participant_emails` | jsonb | yes | '[]' |  |
| `message_count` | integer | yes | 0 |  |
| `unread_count` | integer | yes | 0 |  |
| `has_attachments` | boolean | yes | false |  |
| `snippet` | varchar(320) |  |  |  |
| `last_message_at` | timestamptz | yes | now() |  |
| `last_message_direction` | varchar(16) | yes | 'INBOUND' |  |
| `first_response_at` | timestamptz |  |  |  |
| `resolved_at` | timestamptz |  |  |  |
| `resolved_by` | uuid |  |  | uuid, no foreign key |
| `sla_policy_first_mins` | integer |  |  |  |
| `sla_due_at` | timestamptz |  |  |  |
| `sla_breached_at` | timestamptz |  |  |  |
| `sla_paused_at` | timestamptz |  |  |  |
| `sla_paused_ms` | bigint | yes | 0 |  |
| `spam_score` | numeric(5,2) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-mail-mail-webhook-events"></a>
#### mail.mail_webhook_events

A raw provider webhook, stored so it can be processed once.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `provider` | varchar(24) | yes | 'SES_SNS' |  |
| `provider_event_id` | varchar(120) |  |  |  |
| `event_type` | varchar(80) | yes |  |  |
| `payload` | jsonb | yes |  |  |
| `signature` | varchar(512) |  |  |  |
| `signature_verified` | boolean | yes | false |  |
| `status` | varchar(16) | yes | 'PENDING' |  |
| `attempts` | integer | yes | 0 |  |
| `last_error` | varchar(2000) |  |  |  |
| `organization_id` | uuid |  |  | uuid, no foreign key |
| `received_at` | timestamptz | yes | now() |  |
| `processed_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Mail requests

- [mail_requests](#oneops-public-mail-requests)

<a id="oneops-public-mail-requests"></a>
#### mail_requests

The platform's outbox of 'please send this'. Written in the caller's transaction. No foreign key into the mail schema.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid |  |  | FK → organizations.id ON DELETE CASCADE |
| `template_key` | varchar(80) | yes |  |  |
| `locale` | varchar(16) | yes | 'en' |  |
| `to_addresses` | jsonb | yes | '[]' |  |
| `variables` | jsonb | yes | '{}' |  |
| `dedupe_key` | varchar(200) |  |  |  |
| `priority` | integer | yes | 50 |  |
| `status` | varchar(16) | yes | 'PENDING' |  |
| `attempts` | integer | yes | 0 |  |
| `max_attempts` | integer | yes | 6 |  |
| `next_attempt_at` | timestamptz | yes | now() |  |
| `claimed_at` | timestamptz |  |  |  |
| `claimed_by` | varchar(80) |  |  |  |
| `delivered_at` | timestamptz |  |  |  |
| `outbox_id` | uuid |  |  |  |
| `last_error` | varchar(2000) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Chat

- [chat_canned_replies](#oneops-public-chat-canned-replies)
- [chat_conversations](#oneops-public-chat-conversations)
- [chat_messages](#oneops-public-chat-messages)
- [chat_settings](#oneops-public-chat-settings)

<a id="oneops-public-chat-canned-replies"></a>
#### chat_canned_replies

A saved reply for live chat.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `shortcut` | varchar(60) |  |  |  |
| `title` | varchar(200) | yes |  |  |
| `body` | text | yes |  |  |
| `usage_count` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-public-chat-conversations"></a>
#### chat_conversations

A live chat between a visitor and an agent.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `visitor_id` | uuid |  |  | FK → visitors.id ON DELETE SET NULL |
| `customer_user_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `status` | varchar(16) | yes | 'OPEN' |  |
| `priority` | varchar(16) | yes | 'NORMAL' |  |
| `subject` | varchar(500) |  |  |  |
| `visitor_name` | varchar(160) |  |  |  |
| `visitor_email` | citext |  |  |  |
| `assigned_agent_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `tags` | jsonb | yes | '[]' |  |
| `unread_agent_count` | integer | yes | 0 |  |
| `unread_visitor_count` | integer | yes | 0 |  |
| `last_message_at` | timestamptz |  |  |  |
| `last_message_preview` | varchar(200) |  |  |  |
| `closed_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-public-chat-messages"></a>
#### chat_messages

One message in a live chat.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `conversation_id` | uuid | yes |  | FK → chat_conversations.id ON DELETE CASCADE |
| `sender_type` | varchar(16) | yes |  |  |
| `sender_user_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `body` | text | yes |  |  |
| `file_id` | uuid |  |  | FK → stored_files.id ON DELETE SET NULL |
| `occurred_at` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-public-chat-settings"></a>
#### chat_settings

How an organization's chat widget behaves, including business hours. offline_mailbox_id is a uuid with no foreign key into mail.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | unique; FK → organizations.id ON DELETE CASCADE |
| `availability` | varchar(16) | yes | 'ONLINE' |  |
| `away_message` | varchar(500) |  |  |  |
| `business_hours` | jsonb | yes | '{}' |  |
| `pre_chat_enabled` | boolean | yes | true |  |
| `offline_mailbox_id` | uuid |  |  | FK → mail_mailboxes.id ON DELETE SET NULL |
| `transcript_template_key` | varchar(80) | yes | 'chat.transcript' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `auto_assign_enabled` | boolean | yes | true |  |
| `max_concurrent_conversations` | integer | yes | 5 |  |
| `routing_cursor` | integer | yes | 0 |  |

### Commerce

- [commerce_cart_items](#oneops-public-commerce-cart-items)
- [commerce_carts](#oneops-public-commerce-carts)
- [commerce_customers](#oneops-public-commerce-customers)
- [commerce_discount_codes](#oneops-public-commerce-discount-codes)
- [commerce_discount_redemptions](#oneops-public-commerce-discount-redemptions)
- [commerce_invoices](#oneops-public-commerce-invoices)
- [commerce_order_addresses](#oneops-public-commerce-order-addresses)
- [commerce_order_counters](#oneops-public-commerce-order-counters)
- [commerce_order_downloads](#oneops-public-commerce-order-downloads)
- [commerce_order_events](#oneops-public-commerce-order-events)
- [commerce_order_items](#oneops-public-commerce-order-items)
- [commerce_order_shipments](#oneops-public-commerce-order-shipments)
- [commerce_orders](#oneops-public-commerce-orders)
- [commerce_payments](#oneops-public-commerce-payments)
- [commerce_product_categories](#oneops-public-commerce-product-categories)
- [commerce_product_category_links](#oneops-public-commerce-product-category-links)
- [commerce_product_media](#oneops-public-commerce-product-media)
- [commerce_product_variants](#oneops-public-commerce-product-variants)
- [commerce_products](#oneops-public-commerce-products)
- [commerce_service_engagements](#oneops-public-commerce-service-engagements)
- [commerce_settings](#oneops-public-commerce-settings)
- [commerce_subscriptions](#oneops-public-commerce-subscriptions)
- [commerce_webhook_events](#oneops-public-commerce-webhook-events)

<a id="oneops-public-commerce-cart-items"></a>
#### commerce_cart_items

One line in a cart.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `cart_id` | uuid | yes |  | FK → commerce_carts.id ON DELETE CASCADE |
| `variant_id` | uuid | yes |  | FK → commerce_product_variants.id ON DELETE RESTRICT |
| `quantity` | integer | yes |  |  |
| `unit_price_paise` | bigint | yes |  |  |
| `line_total_paise` | bigint | yes |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-carts"></a>
#### commerce_carts

A shopper's cart. Amounts are integer paise.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `cart_token` | varchar(64) | yes |  | unique |
| `visitor_id` | uuid |  |  | FK → visitors.id ON DELETE SET NULL |
| `currency` | varchar(3) | yes | 'INR' |  |
| `subtotal_paise` | bigint | yes | 0 |  |
| `discount_paise` | bigint | yes | 0 |  |
| `tax_paise` | bigint | yes | 0 |  |
| `shipping_paise` | bigint | yes | 0 |  |
| `total_paise` | bigint | yes | 0 |  |
| `discount_code_id` | uuid |  |  | FK → commerce_discount_codes.id ON DELETE SET NULL |
| `expires_at` | timestamptz | yes |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-customers"></a>
#### commerce_customers

A shopper of an organization's store, distinct from a member of the organization.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `email` | citext | yes |  |  |
| `name` | varchar(160) |  |  |  |
| `phone` | varchar(32) |  |  |  |
| `marketing_consent` | boolean | yes | false |  |
| `visitor_id` | uuid |  |  | FK → visitors.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-discount-codes"></a>
#### commerce_discount_codes

A discount an organization offers. amount_paise is the fixed amount when the discount is not a percentage.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `code` | varchar(40) | yes |  |  |
| `description` | varchar(300) |  |  |  |
| `discount_type` | varchar(16) | yes |  |  |
| `percentage` | integer |  |  |  |
| `amount_paise` | bigint |  |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `min_order_paise` | bigint | yes | 0 |  |
| `max_uses_total` | integer |  |  |  |
| `max_uses_per_customer` | integer |  |  |  |
| `uses_count` | integer | yes | 0 |  |
| `valid_from` | timestamptz |  |  |  |
| `valid_until` | timestamptz |  |  |  |
| `product_ids` | jsonb | yes | '[]' |  |
| `category_ids` | jsonb | yes | '[]' |  |
| `active` | boolean | yes | true |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-public-commerce-discount-redemptions"></a>
#### commerce_discount_redemptions

One use of a discount code on an order.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `discount_code_id` | uuid | yes |  | FK → commerce_discount_codes.id ON DELETE CASCADE |
| `order_id` | uuid |  |  | FK → commerce_orders.id ON DELETE SET NULL |
| `cart_id` | uuid |  |  | FK → commerce_carts.id ON DELETE SET NULL |
| `customer_id` | uuid |  |  | FK → commerce_customers.id ON DELETE SET NULL |
| `amount_paise` | bigint | yes |  |  |
| `redeemed_at` | timestamptz | yes | now() |  |

<a id="oneops-public-commerce-invoices"></a>
#### commerce_invoices

The store's invoice to its shopper. Amounts are paise, including CGST, SGST, and IGST.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | unique; FK → commerce_orders.id ON DELETE RESTRICT |
| `invoice_number` | varchar(40) | yes |  |  |
| `financial_year` | varchar(9) | yes |  |  |
| `sequence_number` | integer | yes |  |  |
| `status` | varchar(16) | yes | 'ISSUED' |  |
| `issue_date` | date | yes |  |  |
| `bill_to_name` | varchar(160) | yes |  |  |
| `bill_to_email` | citext |  |  |  |
| `bill_to_gstin` | varchar(20) |  |  |  |
| `bill_to_address` | jsonb | yes | '{}' |  |
| `line_items` | jsonb | yes | '[]' |  |
| `subtotal_paise` | bigint | yes |  |  |
| `discount_paise` | bigint | yes | 0 |  |
| `cgst_paise` | bigint | yes | 0 |  |
| `sgst_paise` | bigint | yes | 0 |  |
| `igst_paise` | bigint | yes | 0 |  |
| `total_paise` | bigint | yes |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `place_of_supply` | varchar(80) | yes |  |  |
| `pdf_file_id` | uuid |  |  | FK → stored_files.id ON DELETE SET NULL |
| `paid_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-order-addresses"></a>
#### commerce_order_addresses

A billing or shipping address copied onto an order.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | FK → commerce_orders.id ON DELETE CASCADE |
| `address_type` | varchar(16) | yes |  |  |
| `name` | varchar(160) | yes |  |  |
| `line1` | varchar(200) | yes |  |  |
| `line2` | varchar(200) |  |  |  |
| `city` | varchar(100) | yes |  |  |
| `state` | varchar(80) | yes |  |  |
| `pincode` | varchar(12) | yes |  |  |
| `country` | varchar(2) | yes | 'IN' |  |
| `phone` | varchar(32) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-order-counters"></a>
#### commerce_order_counters

The next order number for an organization.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `financial_year` | varchar(9) | yes |  |  |
| `last_sequence` | integer | yes | 0 |  |
| `updated_at` | timestamptz | yes | now() |  |

<a id="oneops-public-commerce-order-downloads"></a>
#### commerce_order_downloads

A file a shopper may download because of an order, and when that right expires.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | FK → commerce_orders.id ON DELETE CASCADE |
| `order_item_id` | uuid | yes |  | unique; FK → commerce_order_items.id ON DELETE CASCADE |
| `file_id` | uuid | yes |  | FK → stored_files.id ON DELETE RESTRICT |
| `download_token` | varchar(64) | yes |  | unique |
| `download_count` | integer | yes | 0 |  |
| `max_download_count` | integer | yes | 5 |  |
| `link_expires_at` | timestamptz | yes |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-order-events"></a>
#### commerce_order_events

A status change on an order.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | FK → commerce_orders.id ON DELETE CASCADE |
| `event_type` | varchar(40) | yes |  |  |
| `message` | varchar(500) |  |  |  |
| `metadata` | jsonb | yes | '{}' |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="oneops-public-commerce-order-items"></a>
#### commerce_order_items

One line on an order, with the price copied at purchase.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | FK → commerce_orders.id ON DELETE CASCADE |
| `product_id` | uuid | yes |  | FK → commerce_products.id ON DELETE RESTRICT |
| `variant_id` | uuid | yes |  | FK → commerce_product_variants.id ON DELETE RESTRICT |
| `product_name` | varchar(200) | yes |  |  |
| `variant_name` | varchar(200) | yes |  |  |
| `sku` | varchar(80) | yes |  |  |
| `product_type` | varchar(16) | yes |  |  |
| `quantity` | integer | yes |  |  |
| `unit_price_paise` | bigint | yes |  |  |
| `line_subtotal_paise` | bigint | yes |  |  |
| `hsn_code` | varchar(20) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-order-shipments"></a>
#### commerce_order_shipments

A shipment against an order.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | FK → commerce_orders.id ON DELETE CASCADE |
| `order_item_id` | uuid | yes |  | unique; FK → commerce_order_items.id ON DELETE CASCADE |
| `status` | varchar(24) | yes | 'PENDING_PICK' |  |
| `carrier` | varchar(80) |  |  |  |
| `tracking_number` | varchar(120) |  |  |  |
| `shipped_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-orders"></a>
#### commerce_orders

A storefront order. Amounts are integer paise.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_number` | varchar(40) | yes |  |  |
| `financial_year` | varchar(9) | yes |  |  |
| `sequence_number` | integer | yes |  |  |
| `status` | varchar(24) | yes | 'PENDING_PAYMENT' |  |
| `customer_id` | uuid |  |  | FK → commerce_customers.id ON DELETE SET NULL |
| `cart_id` | uuid |  |  | FK → commerce_carts.id ON DELETE SET NULL |
| `access_token` | varchar(64) | yes |  | unique |
| `currency` | varchar(3) | yes | 'INR' |  |
| `subtotal_paise` | bigint | yes | 0 |  |
| `discount_paise` | bigint | yes | 0 |  |
| `cgst_paise` | bigint | yes | 0 |  |
| `sgst_paise` | bigint | yes | 0 |  |
| `igst_paise` | bigint | yes | 0 |  |
| `shipping_paise` | bigint | yes | 0 |  |
| `total_paise` | bigint | yes | 0 |  |
| `discount_code_id` | uuid |  |  | FK → commerce_discount_codes.id ON DELETE SET NULL |
| `buyer_state` | varchar(80) |  |  |  |
| `seller_state` | varchar(80) | yes | 'Karnataka' |  |
| `gst_percent` | integer | yes | 18 |  |
| `razorpay_order_id` | varchar(80) |  |  |  |
| `razorpay_payment_id` | varchar(80) |  |  |  |
| `stock_hold_expires_at` | timestamptz |  |  |  |
| `paid_at` | timestamptz |  |  |  |
| `fulfilled_at` | timestamptz |  |  |  |
| `cancelled_at` | timestamptz |  |  |  |
| `internal_note` | text |  |  |  |
| `invoice_id` | uuid |  |  | FK → commerce_invoices.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `subscription_checkout` | boolean | yes | false |  |
| `renewal_subscription_id` | uuid |  |  | FK → commerce_subscriptions.id ON DELETE SET NULL |

<a id="oneops-public-commerce-payments"></a>
#### commerce_payments

A shopper's payment, in paise.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | FK → commerce_orders.id ON DELETE RESTRICT |
| `razorpay_payment_id` | varchar(80) |  |  |  |
| `razorpay_order_id` | varchar(80) |  |  |  |
| `status` | varchar(16) | yes | 'INITIATED' |  |
| `amount_paise` | bigint | yes |  |  |
| `refunded_paise` | bigint | yes | 0 |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `method` | varchar(40) |  |  |  |
| `captured_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-product-categories"></a>
#### commerce_product_categories

A category in an organization's catalog.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `slug` | varchar(120) | yes |  |  |
| `name` | varchar(160) | yes |  |  |
| `description` | varchar(500) |  |  |  |
| `sort_order` | integer | yes | 100 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-public-commerce-product-category-links"></a>
#### commerce_product_category_links

Which categories a product is in. The tenant is implied by the product.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `product_id` | uuid | yes |  | FK → commerce_products.id ON DELETE CASCADE |
| `category_id` | uuid | yes |  | FK → commerce_product_categories.id ON DELETE CASCADE |

<a id="oneops-public-commerce-product-media"></a>
#### commerce_product_media

An image or file on a product, pointing at stored_files.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `product_id` | uuid | yes |  | FK → commerce_products.id ON DELETE CASCADE |
| `file_id` | uuid | yes |  | FK → stored_files.id ON DELETE CASCADE |
| `alt_text` | varchar(300) |  |  |  |
| `sort_order` | integer | yes | 100 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-product-variants"></a>
#### commerce_product_variants

A sellable SKU. price_paise is the price. A digital variant points at a download file.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `product_id` | uuid | yes |  | FK → commerce_products.id ON DELETE CASCADE |
| `name` | varchar(200) | yes |  |  |
| `sku` | varchar(80) | yes |  |  |
| `price_paise` | bigint | yes |  |  |
| `compare_at_price_paise` | bigint |  |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `track_inventory` | boolean | yes | false |  |
| `stock_on_hand` | integer | yes | 0 |  |
| `stock_reserved` | integer | yes | 0 |  |
| `weight_grams` | integer |  |  |  |
| `length_mm` | integer |  |  |  |
| `width_mm` | integer |  |  |  |
| `height_mm` | integer |  |  |  |
| `billing_interval` | varchar(16) |  |  |  |
| `download_file_id` | uuid |  |  | FK → stored_files.id ON DELETE SET NULL |
| `license_terms` | text |  |  |  |
| `service_duration_days` | integer |  |  |  |
| `delivery_sla_days` | integer |  |  |  |
| `sort_order` | integer | yes | 100 |  |
| `active` | boolean | yes | true |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-public-commerce-products"></a>
#### commerce_products

A product in an organization's store.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `slug` | varchar(120) | yes |  |  |
| `name` | varchar(200) | yes |  |  |
| `tagline` | varchar(300) |  |  |  |
| `description` | text |  |  |  |
| `product_type` | varchar(16) | yes |  |  |
| `status` | varchar(16) | yes | 'DRAFT' |  |
| `featured` | boolean | yes | false |  |
| `sort_order` | integer | yes | 100 |  |
| `hero_image_file_id` | uuid |  |  | FK → stored_files.id ON DELETE SET NULL |
| `gallery_file_ids` | jsonb | yes | '[]' |  |
| `seo_title` | varchar(200) |  |  |  |
| `seo_description` | varchar(500) |  |  |  |
| `tax_code` | varchar(20) |  |  |  |
| `hsn_code` | varchar(20) |  |  |  |
| `attributes` | jsonb | yes | '{}' |  |
| `published_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

<a id="oneops-public-commerce-service-engagements"></a>
#### commerce_service_engagements

A sold service, as opposed to a shipped good.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | FK → commerce_orders.id ON DELETE CASCADE |
| `order_item_id` | uuid | yes |  | unique; FK → commerce_order_items.id ON DELETE CASCADE |
| `duration_days` | integer |  |  |  |
| `delivery_sla_days` | integer |  |  |  |
| `status` | varchar(16) | yes | 'ACTIVE' |  |
| `starts_at` | timestamptz | yes | now() |  |
| `ends_at` | timestamptz |  |  |  |
| `sla_due_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-settings"></a>
#### commerce_settings

Storefront settings for one organization, including shipping amounts in paise.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | unique; FK → organizations.id ON DELETE CASCADE |
| `seller_state` | varchar(80) | yes | 'Karnataka' |  |
| `seller_name` | varchar(200) |  |  |  |
| `seller_gstin` | varchar(20) |  |  |  |
| `seller_address` | text |  |  |  |
| `order_number_prefix` | varchar(10) | yes | 'ORD' |  |
| `gst_percent` | integer | yes | 18 |  |
| `flat_shipping_paise` | bigint | yes | 0 |  |
| `free_shipping_above_paise` | bigint |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-subscriptions"></a>
#### commerce_subscriptions

A shopper's subscription to a product, with the price locked at purchase.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `customer_id` | uuid | yes |  | FK → commerce_customers.id ON DELETE RESTRICT |
| `order_id` | uuid | yes |  | FK → commerce_orders.id ON DELETE RESTRICT |
| `order_item_id` | uuid | yes |  | unique; FK → commerce_order_items.id ON DELETE RESTRICT |
| `product_id` | uuid | yes |  | FK → commerce_products.id ON DELETE RESTRICT |
| `variant_id` | uuid | yes |  | FK → commerce_product_variants.id ON DELETE RESTRICT |
| `status` | varchar(16) | yes | 'ACTIVE' |  |
| `billing_interval` | varchar(16) | yes |  |  |
| `current_period_start` | timestamptz | yes | now() |  |
| `current_period_end` | timestamptz | yes |  |  |
| `next_billing_at` | timestamptz |  |  |  |
| `locked_price_paise` | bigint | yes |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `razorpay_token_id` | varchar(80) |  |  |  |
| `failed_payment_count` | integer | yes | 0 |  |
| `next_dunning_retry_at` | timestamptz |  |  |  |
| `cancelled_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-commerce-webhook-events"></a>
#### commerce_webhook_events

A raw payment webhook for the store, processed once.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid |  |  |  |
| `order_id` | uuid |  |  |  |
| `provider` | varchar(16) | yes | 'RAZORPAY' |  |
| `provider_event_id` | varchar(80) |  |  |  |
| `event_type` | varchar(80) | yes |  |  |
| `payload` | jsonb | yes |  |  |
| `signature` | varchar(128) |  |  |  |
| `signature_verified` | boolean | yes | false |  |
| `status` | varchar(16) | yes | 'PENDING' |  |
| `attempts` | integer | yes | 0 |  |
| `last_error` | text |  |  |  |
| `received_at` | timestamptz | yes | now() |  |
| `processed_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |

### Billing

- [billing_invoice_counters](#oneops-public-billing-invoice-counters)
- [billing_invoices](#oneops-public-billing-invoices)
- [billing_orders](#oneops-public-billing-orders)
- [billing_payments](#oneops-public-billing-payments)
- [billing_plans](#oneops-public-billing-plans)
- [billing_subscriptions](#oneops-public-billing-subscriptions)
- [billing_webhook_events](#oneops-public-billing-webhook-events)

<a id="oneops-public-billing-invoice-counters"></a>
#### billing_invoice_counters

The next invoice number for a financial year. Global, not per organization.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `financial_year` | varchar(9) | yes |  | primary key |
| `last_sequence` | integer | yes | 0 |  |
| `updated_at` | timestamptz | yes | now() |  |

<a id="oneops-public-billing-invoices"></a>
#### billing_invoices

A GST invoice for an organization's subscription. Amounts are integer paise, and the total is checked.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid |  |  | FK → billing_orders.id ON DELETE SET NULL |
| `subscription_id` | uuid |  |  | FK → billing_subscriptions.id ON DELETE SET NULL |
| `invoice_number` | varchar(60) | yes |  | unique |
| `financial_year` | varchar(9) | yes |  |  |
| `sequence_number` | integer | yes |  |  |
| `status` | varchar(16) | yes | 'ISSUED' |  |
| `issue_date` | date | yes | CURRENT_DATE |  |
| `due_date` | date |  |  |  |
| `paid_at` | timestamptz |  |  |  |
| `bill_to_name` | varchar(250) | yes |  |  |
| `bill_to_address` | jsonb | yes | '{}' |  |
| `bill_to_gstin` | varchar(15) |  |  |  |
| `bill_to_email` | citext |  |  |  |
| `line_items` | jsonb | yes | '[]' |  |
| `subtotal_paise` | bigint | yes |  |  |
| `discount_paise` | bigint | yes | 0 |  |
| `cgst_paise` | bigint | yes | 0 |  |
| `sgst_paise` | bigint | yes | 0 |  |
| `igst_paise` | bigint | yes | 0 |  |
| `total_paise` | bigint | yes |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `sac_code` | varchar(12) | yes | '998314' |  |
| `place_of_supply` | varchar(80) |  |  |  |
| `notes` | varchar(1000) |  |  |  |
| `pdf_file_id` | uuid |  |  | FK → stored_files.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-billing-orders"></a>
#### billing_orders

In oneOps, a Razorpay order for a subscription charge. In MobiStack, a shop's order for a plan or an extra screen. Amounts differ: paise in oneOps, rupees in MobiStack.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `subscription_id` | uuid |  |  | FK → billing_subscriptions.id ON DELETE SET NULL |
| `plan_id` | uuid |  |  | FK → billing_plans.id ON DELETE SET NULL |
| `purpose` | varchar(32) | yes |  |  |
| `amount_paise` | bigint | yes |  |  |
| `tax_paise` | bigint | yes | 0 |  |
| `total_paise` | bigint | yes |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `status` | varchar(16) | yes | 'CREATED' |  |
| `razorpay_order_id` | varchar(80) |  |  |  |
| `razorpay_payment_id` | varchar(80) |  |  |  |
| `receipt` | varchar(80) | yes |  | unique |
| `notes` | jsonb | yes | '{}' |  |
| `failure_reason` | varchar(500) |  |  |  |
| `captured_at` | timestamptz |  |  |  |
| `initiated_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `expires_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-billing-payments"></a>
#### billing_payments

A captured or refunded subscription payment, in paise.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `order_id` | uuid | yes |  | FK → billing_orders.id ON DELETE RESTRICT |
| `razorpay_payment_id` | varchar(80) | yes |  | unique |
| `amount_paise` | bigint | yes |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `status` | varchar(16) | yes |  |  |
| `method` | varchar(32) |  |  |  |
| `method_detail` | varchar(120) |  |  |  |
| `bank` | varchar(80) |  |  |  |
| `wallet` | varchar(80) |  |  |  |
| `vpa` | varchar(120) |  |  |  |
| `signature_verified` | boolean | yes | false |  |
| `error_code` | varchar(80) |  |  |  |
| `error_description` | varchar(500) |  |  |  |
| `fee_paise` | bigint |  |  |  |
| `tax_paise` | bigint |  |  |  |
| `refunded_paise` | bigint | yes | 0 |  |
| `captured_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-billing-plans"></a>
#### billing_plans

A plan a customer can buy. In oneOps the price is paise. In MobiStack the price is rupees and the feature list is separate.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `plan_key` | varchar(60) | yes |  | unique |
| `name` | varchar(120) | yes |  |  |
| `description` | varchar(500) |  |  |  |
| `interval_type` | varchar(16) | yes | 'MONTHLY' |  |
| `amount_paise` | bigint | yes |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `per_seat_paise` | bigint | yes | 0 |  |
| `included_seats` | integer | yes | 5 |  |
| `max_seats` | integer |  |  |  |
| `trial_days` | integer | yes | 0 |  |
| `entitlements` | jsonb | yes | '{}' |  |
| `razorpay_plan_id` | varchar(80) |  |  |  |
| `is_public` | boolean | yes | true |  |
| `is_active` | boolean | yes | true |  |
| `rank` | integer | yes | 100 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-billing-subscriptions"></a>
#### billing_subscriptions

An organization's current subscription, including the price locked at purchase.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `plan_id` | uuid | yes |  | FK → billing_plans.id ON DELETE RESTRICT |
| `status` | varchar(24) | yes | 'TRIALING' |  |
| `seats` | integer | yes | 5 |  |
| `current_period_start` | timestamptz | yes | now() |  |
| `current_period_end` | timestamptz | yes |  |  |
| `trial_ends_at` | timestamptz |  |  |  |
| `cancel_at_period_end` | boolean | yes | false |  |
| `cancelled_at` | timestamptz |  |  |  |
| `cancellation_reason` | varchar(500) |  |  |  |
| `grace_period_ends_at` | timestamptz |  |  |  |
| `failed_payment_count` | integer | yes | 0 |  |
| `last_payment_at` | timestamptz |  |  |  |
| `next_billing_at` | timestamptz |  |  |  |
| `razorpay_subscription_id` | varchar(80) |  |  |  |
| `razorpay_customer_id` | varchar(80) |  |  |  |
| `locked_amount_paise` | bigint | yes |  |  |
| `locked_per_seat_paise` | bigint | yes | 0 |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `pending_plan_id` | uuid |  |  | FK → billing_plans.id ON DELETE SET NULL |
| `pending_seats` | integer |  |  |  |
| `pending_change_at` | timestamptz |  |  |  |
| `next_dunning_retry_at` | timestamptz |  |  |  |
| `razorpay_token_id` | varchar(80) |  |  |  |

<a id="oneops-public-billing-webhook-events"></a>
#### billing_webhook_events

A raw Razorpay webhook, stored so the same event is applied once.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `provider` | varchar(24) | yes | 'RAZORPAY' |  |
| `provider_event_id` | varchar(120) |  |  |  |
| `event_type` | varchar(80) | yes |  |  |
| `payload` | jsonb | yes |  |  |
| `signature` | varchar(255) |  |  |  |
| `signature_verified` | boolean | yes | false |  |
| `status` | varchar(16) | yes | 'PENDING' |  |
| `attempts` | integer | yes | 0 |  |
| `last_error` | varchar(2000) |  |  |  |
| `organization_id` | uuid |  |  | FK → organizations.id ON DELETE SET NULL |
| `order_id` | uuid |  |  | FK → billing_orders.id ON DELETE SET NULL |
| `received_at` | timestamptz | yes | now() |  |
| `processed_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Visitors

- [visitor_daily_aggregates](#oneops-public-visitor-daily-aggregates)
- [visitor_events](#oneops-public-visitor-events)
- [visitor_page_views](#oneops-public-visitor-page-views)
- [visitor_sessions](#oneops-public-visitor-sessions)
- [visitors](#oneops-public-visitors)

<a id="oneops-public-visitor-daily-aggregates"></a>
#### visitor_daily_aggregates

A daily rollup of page views, sessions, and visitors.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `aggregate_date` | date | yes |  |  |
| `metric_type` | varchar(24) | yes |  |  |
| `dimension` | varchar(500) | yes | '' |  |
| `count_value` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |

<a id="oneops-public-visitor-events"></a>
#### visitor_events

A named event from the beacon, with a jsonb payload.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `visitor_id` | uuid | yes |  | FK → visitors.id ON DELETE CASCADE |
| `session_id` | uuid |  |  | FK → visitor_sessions.id ON DELETE SET NULL |
| `event_name` | varchar(120) | yes |  |  |
| `properties` | jsonb | yes | '{}' |  |
| `occurred_at` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-visitor-page-views"></a>
#### visitor_page_views

A page viewed inside a session.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `visitor_id` | uuid | yes |  | FK → visitors.id ON DELETE CASCADE |
| `session_id` | uuid | yes |  | FK → visitor_sessions.id ON DELETE CASCADE |
| `url` | varchar(2000) | yes |  |  |
| `path` | varchar(500) | yes |  |  |
| `title` | varchar(500) |  |  |  |
| `referrer` | varchar(500) |  |  |  |
| `viewed_at` | timestamptz | yes | now() |  |
| `duration_ms` | integer |  |  |  |
| `is_entry` | boolean | yes | false |  |
| `is_exit` | boolean | yes | false |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-visitor-sessions"></a>
#### visitor_sessions

One visit: device, referrer, and UTM.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `visitor_id` | uuid | yes |  | FK → visitors.id ON DELETE CASCADE |
| `started_at` | timestamptz | yes | now() |  |
| `ended_at` | timestamptz |  |  |  |
| `duration_seconds` | integer |  |  |  |
| `entry_url` | varchar(2000) |  |  |  |
| `exit_url` | varchar(2000) |  |  |  |
| `referrer` | varchar(500) |  |  |  |
| `device_type` | varchar(32) |  |  |  |
| `browser` | varchar(80) |  |  |  |
| `os` | varchar(80) |  |  |  |
| `screen_width` | integer |  |  |  |
| `screen_height` | integer |  |  |  |
| `language` | varchar(16) |  |  |  |
| `timezone` | varchar(64) |  |  |  |
| `ip_address` | varchar(45) |  |  |  |
| `geo_country` | varchar(2) |  |  |  |
| `geo_region` | varchar(80) |  |  |  |
| `geo_city` | varchar(120) |  |  |  |
| `utm` | jsonb | yes | '{}' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-visitors"></a>
#### visitors

An anonymous or identified visitor on an organization's site.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `external_key` | varchar(64) | yes |  |  |
| `consent_status` | varchar(16) | yes | 'FULL' |  |
| `first_seen_at` | timestamptz | yes | now() |  |
| `last_seen_at` | timestamptz | yes | now() |  |
| `identified_user_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `email` | citext |  |  |  |
| `display_name` | varchar(160) |  |  |  |
| `first_touch_utm` | jsonb | yes | '{}' |  |
| `first_touch_referrer` | varchar(500) |  |  |  |
| `merged_into_id` | uuid |  |  | FK → visitors.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |
| `identified_at` | timestamptz |  |  |  |

### Marketing site

- [site_job_applications](#oneops-public-site-job-applications)
- [site_job_roles](#oneops-public-site-job-roles)
- [site_leads](#oneops-public-site-leads)
- [site_subscribers](#oneops-public-site-subscribers)

<a id="oneops-public-site-job-applications"></a>
#### site_job_applications

An application to one of those roles, including the resume file.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `role_id` | uuid |  |  | FK → site_job_roles.id ON DELETE SET NULL |
| `role_slug` | varchar(120) | yes |  |  |
| `name` | varchar(160) | yes |  |  |
| `email` | citext | yes |  |  |
| `phone` | varchar(32) |  |  |  |
| `portfolio_url` | varchar(500) |  |  |  |
| `linkedin_url` | varchar(500) |  |  |  |
| `cover_letter` | varchar(8000) |  |  |  |
| `resume_file_id` | uuid |  |  | FK → stored_files.id ON DELETE SET NULL |
| `status` | varchar(16) | yes | 'RECEIVED' |  |
| `internal_notes` | varchar(4000) |  |  |  |
| `ip_address` | varchar(45) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-site-job-roles"></a>
#### site_job_roles

A role listed on Prabhix's careers page.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `slug` | varchar(120) | yes |  | unique |
| `title` | varchar(200) | yes |  |  |
| `department` | varchar(120) | yes |  |  |
| `location` | varchar(160) | yes |  |  |
| `employment_type` | varchar(24) | yes | 'FULL_TIME' |  |
| `work_mode` | varchar(16) | yes | 'HYBRID' |  |
| `experience_range` | varchar(60) |  |  |  |
| `salary_range` | varchar(80) |  |  |  |
| `summary` | varchar(1000) | yes |  |  |
| `description_md` | text | yes |  |  |
| `status` | varchar(16) | yes | 'OPEN' |  |
| `published_at` | timestamptz |  |  |  |
| `closed_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-site-leads"></a>
#### site_leads

A lead from Prabhix's own marketing site. No organization_id: this is not a customer tenant.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `name` | varchar(160) | yes |  |  |
| `email` | citext | yes |  |  |
| `company` | varchar(200) |  |  |  |
| `phone` | varchar(32) |  |  |  |
| `employee_count` | varchar(32) |  |  |  |
| `interest` | varchar(32) | yes | 'OTHER' |  |
| `message` | varchar(4000) | yes |  |  |
| `source` | varchar(80) | yes | 'contact-form' |  |
| `utm` | jsonb | yes | '{}' |  |
| `referrer` | varchar(500) |  |  |  |
| `ip_address` | varchar(45) |  |  |  |
| `user_agent` | varchar(500) |  |  |  |
| `status` | varchar(16) | yes | 'NEW' |  |
| `assigned_to` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `internal_notes` | varchar(4000) |  |  |  |
| `thread_id` | uuid |  |  | FK → mail_threads.id ON DELETE SET NULL |
| `contacted_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `interest_raw` | varchar(120) |  |  |  |

<a id="oneops-public-site-subscribers"></a>
#### site_subscribers

An address subscribed on the marketing site.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `email` | citext | yes |  | unique |
| `name` | varchar(160) |  |  |  |
| `source` | varchar(80) | yes | 'footer' |  |
| `status` | varchar(16) | yes | 'PENDING' |  |
| `confirm_token_hash` | varchar(64) |  |  |  |
| `confirmed_at` | timestamptz |  |  |  |
| `unsubscribed_at` | timestamptz |  |  |  |
| `unsubscribe_token` | varchar(80) | yes |  | unique |
| `ip_address` | varchar(45) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### AI

- [ai_model_rates](#oneops-public-ai-model-rates)
- [ai_org_settings](#oneops-public-ai-org-settings)
- [ai_prompts](#oneops-public-ai-prompts)
- [ai_usage](#oneops-public-ai-usage)

<a id="oneops-public-ai-model-rates"></a>
#### ai_model_rates

What a model costs, in paise per million tokens, from a given date.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `provider` | varchar(32) | yes |  |  |
| `model` | varchar(80) | yes |  |  |
| `prompt_paise_per_million` | numeric(14,4) | yes | 0 |  |
| `completion_paise_per_million` | numeric(14,4) | yes | 0 |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `effective_from` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-ai-org-settings"></a>
#### ai_org_settings

Which models an organization prefers, and whether the first responder is on.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | unique; FK → organizations.id ON DELETE CASCADE |
| `preferred_provider` | varchar(32) |  |  |  |
| `preferred_chat_model` | varchar(80) |  |  |  |
| `preferred_reasoning_model` | varchar(80) |  |  |  |
| `first_responder_enabled` | boolean | yes | false |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-ai-prompts"></a>
#### ai_prompts

A prompt template, either the platform default or an organization's own.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid |  |  | FK → organizations.id ON DELETE CASCADE |
| `task_key` | varchar(80) | yes |  |  |
| `name` | varchar(160) | yes |  |  |
| `description` | varchar(500) |  |  |  |
| `template` | text | yes |  |  |
| `provider` | varchar(32) |  |  |  |
| `model` | varchar(80) |  |  |  |
| `temperature` | float8 | yes | 0.3 |  |
| `prompt_version` | integer | yes | 1 |  |
| `enabled` | boolean | yes | true |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-ai-usage"></a>
#### ai_usage

Tokens and estimated paise for one model call.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `feature` | varchar(80) | yes |  |  |
| `task_key` | varchar(80) |  |  |  |
| `provider` | varchar(32) | yes |  |  |
| `model` | varchar(80) | yes |  |  |
| `prompt_tokens` | integer | yes | 0 |  |
| `completion_tokens` | integer | yes | 0 |  |
| `total_tokens` | integer | yes | 0 |  |
| `latency_ms` | integer | yes | 0 |  |
| `outcome` | varchar(16) | yes |  |  |
| `cost_estimate_paise` | bigint | yes | 0 |  |
| `pii_redacted` | boolean | yes | false |  |
| `correlation_type` | varchar(40) |  |  |  |
| `correlation_id` | uuid |  |  |  |
| `error_code` | varchar(40) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Push

- [push_outbox](#oneops-public-push-outbox)
- [push_tokens](#oneops-public-push-tokens)

<a id="oneops-public-push-outbox"></a>
#### push_outbox

A push notification waiting to be sent.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `push_token_id` | uuid | yes |  | FK → push_tokens.id ON DELETE CASCADE |
| `notification_type` | varchar(64) | yes |  |  |
| `payload` | jsonb | yes | '{}' |  |
| `dedupe_key` | varchar(200) |  |  |  |
| `status` | varchar(16) | yes | 'PENDING' |  |
| `attempts` | integer | yes | 0 |  |
| `max_attempts` | integer | yes | 6 |  |
| `scheduled_at` | timestamptz | yes | now() |  |
| `next_attempt_at` | timestamptz |  |  |  |
| `claimed_at` | timestamptz |  |  |  |
| `claimed_by` | varchar(80) |  |  |  |
| `sent_at` | timestamptz |  |  |  |
| `last_error` | varchar(2000) |  |  |  |
| `provider_used` | varchar(32) |  |  |  |
| `provider_message_id` | varchar(255) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-push-tokens"></a>
#### push_tokens

A device token for push, belonging to one person in one organization.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `platform` | varchar(8) | yes |  |  |
| `token` | varchar(512) | yes |  | unique |
| `device_id` | varchar(120) | yes |  |  |
| `device_name` | varchar(160) |  |  |  |
| `app_version` | varchar(32) |  |  |  |
| `last_seen_at` | timestamptz | yes | now() |  |
| `enabled` | boolean | yes | true |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `deleted_at` | timestamptz |  |  |  |

### Flags

- [feature_flag_overrides](#oneops-public-feature-flag-overrides)
- [feature_flags](#oneops-public-feature-flags)

<a id="oneops-public-feature-flag-overrides"></a>
#### feature_flag_overrides

Turns a flag on or off for one organization.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `organization_id` | uuid | yes |  | FK → organizations.id ON DELETE CASCADE |
| `flag_key` | varchar(80) | yes |  | FK → feature_flags.flag_key ON DELETE CASCADE |
| `enabled` | boolean | yes |  |  |
| `reason` | varchar(255) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="oneops-public-feature-flags"></a>
#### feature_flags

A flag definition. In oneOps the definition is global and overrides are per organization. In MobiStack the row itself is per shop.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `version` | bigint | yes | 0 |  |
| `flag_key` | varchar(80) | yes |  | unique |
| `description` | varchar(255) |  |  |  |
| `default_enabled` | boolean | yes | false |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Audit

- [audit_archive_records](#oneops-public-audit-archive-records)
- [audit_logs](#oneops-public-audit-logs)

<a id="oneops-public-audit-archive-records"></a>
#### audit_archive_records

Where an expired audit partition was copied when it was archived.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `partition_name` | varchar(64) | yes |  | primary key |
| `archived_at` | timestamptz | yes | now() |  |
| `storage_bucket` | varchar(120) | yes |  |  |
| `storage_keys` | jsonb | yes |  |  |
| `row_count` | bigint | yes |  |  |
| `content_sha256` | varchar(64) | yes |  |  |
| `detached_at` | timestamptz |  |  |  |
| `dropped_at` | timestamptz |  |  |  |

<a id="oneops-public-audit-logs"></a>
#### audit_logs

Append-only record of who changed what. Partitioned by month.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |  |
| `organization_id` | uuid |  |  |  |
| `actor_user_id` | uuid |  |  |  |
| `actor_email` | citext |  |  |  |
| `actor_type` | varchar(24) | yes | 'USER' |  |
| `action` | varchar(80) | yes |  |  |
| `resource_type` | varchar(64) |  |  |  |
| `resource_id` | uuid |  |  |  |
| `resource_label` | varchar(255) |  |  |  |
| `changes` | jsonb |  |  |  |
| `metadata` | jsonb | yes | '{}' |  |
| `ip_address` | varchar(45) |  |  |  |
| `user_agent` | varchar(500) |  |  |  |
| `outcome` | varchar(16) | yes | 'SUCCESS' |  |
| `created_at` | timestamptz | yes | now() |  |

### Observability

- [event_logs](#oneops-public-event-logs)
- [system_health_snapshots](#oneops-public-system-health-snapshots)

<a id="oneops-public-event-logs"></a>
#### event_logs

Structured product events for the operator console. Partitioned by month.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() |  |
| `organization_id` | uuid |  |  |  |
| `event_code` | varchar(80) | yes |  |  |
| `category` | varchar(32) | yes |  |  |
| `severity` | varchar(16) | yes |  |  |
| `correlation_id` | varchar(64) | yes |  |  |
| `actor_user_id` | uuid |  |  |  |
| `actor_type` | varchar(24) | yes | 'SYSTEM' |  |
| `actor_label` | varchar(255) |  |  |  |
| `target_type` | varchar(64) |  |  |  |
| `target_id` | uuid |  |  |  |
| `payload` | jsonb | yes | '{}' |  |
| `ip_address` | varchar(45) |  |  |  |
| `user_agent` | varchar(500) |  |  |  |
| `security_event` | boolean | yes | false |  |
| `contains_pii` | boolean | yes | false |  |
| `occurred_at` | timestamptz | yes | now() |  |

<a id="oneops-public-system-health-snapshots"></a>
#### system_health_snapshots

A point-in-time reading of platform health for the admin console.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `organization_id` | uuid |  |  |  |
| `bucket_start` | timestamptz | yes |  |  |
| `bucket_granularity` | varchar(8) | yes | 'HOUR' |  |
| `error_count` | bigint | yes | 0 |  |
| `warn_count` | bigint | yes | 0 |  |
| `request_count` | bigint | yes | 0 |  |
| `slow_request_count` | bigint | yes | 0 |  |
| `mail_outbox_pending` | bigint | yes | 0 |  |
| `mail_outbox_failed` | bigint | yes | 0 |  |
| `payment_failures` | bigint | yes | 0 |  |
| `ai_tokens_used` | bigint | yes | 0 |  |
| `chat_queue_wait_ms` | bigint | yes | 0 |  |
| `active_visitors` | bigint | yes | 0 |  |
| `top_event_codes` | jsonb | yes | '[]' |  |
| `created_at` | timestamptz | yes | now() |  |

## mobistack

Database `mobistack`, role `mobistack`. Money in this database is `numeric(14,2)` rupees. The tenant column is `shop_id`. The shared fitment tables have no shop.

60 tables.

### Shop

- [shop_entitlements](#mobistack-public-shop-entitlements)
- [shop_invitations](#mobistack-public-shop-invitations)
- [shop_memberships](#mobistack-public-shop-memberships)
- [shop_subscriptions](#mobistack-public-shop-subscriptions)
- [shops](#mobistack-public-shops)

<a id="mobistack-public-shop-entitlements"></a>
#### shop_entitlements

A feature a shop has been granted, and the billing order that paid for it.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `code` | varchar(40) | yes |  |  |
| `active` | boolean | yes | true |  |
| `source_order_id` | uuid |  |  | FK → billing_orders.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `expires_at` | timestamptz |  |  |  |

<a id="mobistack-public-shop-invitations"></a>
#### shop_invitations

An invitation to join a shop.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `email` | varchar(255) |  |  |  |
| `phone` | varchar(32) |  |  |  |
| `role_id` | uuid | yes |  | FK → roles.id ON DELETE RESTRICT |
| `token_hash` | varchar(88) | yes |  | unique |
| `raw_hint` | varchar(12) | yes |  |  |
| `status` | varchar(20) | yes |  |  |
| `expires_at` | timestamptz | yes |  |  |
| `invited_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `accepted_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `version` | bigint | yes | 0 |  |

<a id="mobistack-public-shop-memberships"></a>
#### shop_memberships

A person's membership in a shop, and the role they hold there.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `role_id` | uuid | yes |  | FK → roles.id ON DELETE RESTRICT |
| `status` | varchar(20) | yes |  |  |
| `invited_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `joined_at` | timestamptz |  |  |  |
| `last_selected_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `version` | bigint | yes | 0 |  |

<a id="mobistack-public-shop-subscriptions"></a>
#### shop_subscriptions

The plan a shop is on. The primary key is the shop.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `shop_id` | uuid | yes |  | primary key; FK → shops.id ON DELETE CASCADE |
| `plan_id` | uuid |  |  | FK → billing_plans.id ON DELETE SET NULL |
| `status` | varchar(20) | yes | 'NONE' |  |
| `period_end` | timestamptz |  |  |  |
| `source_order_id` | uuid |  |  | FK → billing_orders.id ON DELETE SET NULL |
| `updated_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-shops"></a>
#### shops

A repair shop, the tenant of MobiStack. Join code, invoice numbers, and GST details live on this row.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `name` | varchar(160) | yes |  |  |
| `legal_name` | varchar(200) |  |  |  |
| `phone` | varchar(32) |  |  |  |
| `email` | varchar(255) |  |  |  |
| `address_line1` | varchar(255) |  |  |  |
| `address_line2` | varchar(255) |  |  |  |
| `city` | varchar(120) |  |  |  |
| `state` | varchar(120) |  |  |  |
| `postal_code` | varchar(20) |  |  |  |
| `country` | varchar(80) |  | 'India' |  |
| `gst_number` | varchar(20) |  |  |  |
| `currency_code` | varchar(3) | yes | 'INR' |  |
| `timezone` | varchar(64) | yes | 'Asia/Kolkata' |  |
| `logo_url` | text |  |  |  |
| `invoice_prefix` | varchar(12) | yes | 'INV' |  |
| `invoice_next_number` | bigint | yes | 1 |  |
| `settings` | jsonb | yes | '{}' |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `join_code` | varchar(16) | yes |  |  |
| `repair_prefix` | varchar(12) | yes | 'JOB' |  |
| `repair_next_number` | bigint | yes | 1 |  |
| `require_compatibility_approval` | boolean | yes | false |  |
| `max_devices_per_user` | integer | yes | 3 |  |
| `extra_screens` | integer | yes | 0 |  |
| `extra_screens_period_end` | timestamptz |  |  |  |

### People

- [permissions](#mobistack-public-permissions)
- [role_permissions](#mobistack-public-role-permissions)
- [roles](#mobistack-public-roles)
- [user_roles](#mobistack-public-user-roles)
- [users](#mobistack-public-users)

<a id="mobistack-public-permissions"></a>
#### permissions

The catalog of shop permission codes. Separate from oneOps permissions.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `code` | varchar(64) | yes |  | unique |
| `resource` | varchar(40) | yes |  |  |
| `action` | varchar(40) | yes |  |  |
| `description` | varchar(255) | yes |  |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-role-permissions"></a>
#### role_permissions

Which permissions a role includes.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `role_id` | uuid | yes |  | FK → roles.id ON DELETE CASCADE |
| `permission_id` | uuid | yes |  | FK → permissions.id ON DELETE CASCADE |

<a id="mobistack-public-roles"></a>
#### roles

A bundle of shop permissions. shop_id null means a system role shared by every shop.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid |  |  | FK → shops.id ON DELETE CASCADE |
| `code` | varchar(40) | yes |  |  |
| `name` | varchar(80) | yes |  |  |
| `description` | varchar(255) |  |  |  |
| `system_role` | boolean | yes | false |  |
| `seniority` | integer | yes | 100 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-user-roles"></a>
#### user_roles

Which roles a person holds. This is global to the person, not per shop. Shop authority is shop_memberships.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `role_id` | uuid | yes |  | FK → roles.id ON DELETE CASCADE |

<a id="mobistack-public-users"></a>
#### users

MobiStack's mirror of a person. The id matches Identity. There is no password column. email is citext. system_admin is the platform-admin flag for this product. Shop access is shop_memberships, not this row.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid |  |  | FK → shops.id ON DELETE CASCADE |
| `full_name` | varchar(160) | yes |  |  |
| `email` | citext | yes |  |  |
| `phone` | varchar(32) |  |  |  |
| `avatar_url` | text |  |  |  |
| `active` | boolean | yes | true |  |
| `last_login_at` | timestamptz |  |  |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `email_verified` | boolean | yes | false |  |
| `phone_verified` | boolean | yes | false |  |
| `system_admin` | boolean | yes | false |  |

### Shop catalog

- [brands](#mobistack-public-brands)
- [categories](#mobistack-public-categories)
- [compatibility_change_requests](#mobistack-public-compatibility-change-requests)
- [compatibility_group_devices](#mobistack-public-compatibility-group-devices)
- [compatibility_groups](#mobistack-public-compatibility-groups)
- [compatibility_history](#mobistack-public-compatibility-history)
- [device_aliases](#mobistack-public-device-aliases)
- [device_models](#mobistack-public-device-models)
- [product_compatibilities](#mobistack-public-product-compatibilities)
- [product_variants](#mobistack-public-product-variants)
- [products](#mobistack-public-products)

<a id="mobistack-public-brands"></a>
#### brands

A brand in one shop's private catalog.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `name` | varchar(80) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `logo_url` | text |  |  |  |
| `color` | varchar(9) |  |  |  |
| `sort_order` | integer | yes | 100 |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="mobistack-public-categories"></a>
#### categories

A category in one shop's private catalog.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `parent_id` | uuid |  |  | FK → categories.id ON DELETE SET NULL |
| `code` | varchar(48) | yes |  |  |
| `name` | varchar(80) | yes |  |  |
| `icon` | varchar(48) |  |  |  |
| `color` | varchar(9) |  |  |  |
| `sort_order` | integer | yes | 100 |  |
| `compatibility_relevant` | boolean | yes | true |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="mobistack-public-compatibility-change-requests"></a>
#### compatibility_change_requests

A proposed fitment change waiting for the shop's approval.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `group_id` | uuid | yes |  | FK → compatibility_groups.id ON DELETE CASCADE |
| `action` | varchar(20) | yes |  |  |
| `device_id` | uuid |  |  | FK → device_models.id ON DELETE CASCADE |
| `reason` | varchar(255) |  |  |  |
| `status` | varchar(20) | yes |  |  |
| `requested_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `reviewed_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `reviewed_at` | timestamptz |  |  |  |

<a id="mobistack-public-compatibility-group-devices"></a>
#### compatibility_group_devices

A phone in a compatibility group.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `compatibility_group_id` | uuid | yes |  | FK → compatibility_groups.id ON DELETE CASCADE |
| `device_model_id` | uuid | yes |  | FK → device_models.id ON DELETE CASCADE |
| `primary_device` | boolean | yes | false |  |
| `note` | varchar(255) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-compatibility-groups"></a>
#### compatibility_groups

A set of phones a shop treats as sharing parts.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `category_id` | uuid |  |  | FK → categories.id ON DELETE SET NULL |
| `code` | varchar(64) | yes |  |  |
| `name` | varchar(160) | yes |  |  |
| `notes` | text |  |  |  |
| `verified` | boolean | yes | false |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="mobistack-public-compatibility-history"></a>
#### compatibility_history

The before and after of a shop's fitment edit.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `group_id` | uuid | yes |  | FK → compatibility_groups.id ON DELETE CASCADE |
| `actor_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `actor_name` | varchar(160) |  |  |  |
| `summary` | text | yes |  |  |
| `reason` | varchar(255) |  |  |  |
| `before_data` | jsonb |  |  |  |
| `after_data` | jsonb |  |  |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-device-aliases"></a>
#### device_aliases

Another name a shop uses for one of its phone models.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `device_model_id` | uuid | yes |  | FK → device_models.id ON DELETE CASCADE |
| `alias` | varchar(120) | yes |  |  |
| `normalized_alias` | text |  |  |  |
| `source` | varchar(24) | yes | 'MANUAL' |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-device-models"></a>
#### device_models

A phone model in one shop's private catalog.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `brand_id` | uuid | yes |  | FK → brands.id ON DELETE CASCADE |
| `name` | varchar(120) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `model_code` | varchar(60) |  |  |  |
| `release_year` | integer |  |  |  |
| `popularity` | integer | yes | 0 |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `variant` | varchar(40) |  |  |  |

<a id="mobistack-public-product-compatibilities"></a>
#### product_compatibilities

A shop's own note that a part fits a phone.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `product_id` | uuid | yes |  | FK → products.id ON DELETE CASCADE |
| `compatibility_group_id` | uuid |  |  | FK → compatibility_groups.id ON DELETE CASCADE |
| `device_model_id` | uuid |  |  | FK → device_models.id ON DELETE CASCADE |
| `fit_quality` | varchar(16) | yes | 'EXACT' |  |
| `note` | varchar(255) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-product-variants"></a>
#### product_variants

A SKU of a shop part: cost, retail, wholesale, repair, and on-hand quantity. Prices are rupees.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `product_id` | uuid | yes |  | FK → products.id ON DELETE CASCADE |
| `supplier_id` | uuid |  |  | FK → suppliers.id ON DELETE SET NULL |
| `sku` | varchar(64) | yes |  |  |
| `barcode` | varchar(64) |  |  |  |
| `variant_name` | varchar(160) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `grade` | varchar(24) |  |  |  |
| `quality` | varchar(40) |  |  |  |
| `color` | varchar(40) |  |  |  |
| `cost_price` | numeric(14,2) | yes | 0 |  |
| `retail_price` | numeric(14,2) | yes | 0 |  |
| `wholesale_price` | numeric(14,2) |  |  |  |
| `repair_price` | numeric(14,2) |  |  |  |
| `min_price` | numeric(14,2) |  |  |  |
| `clearance_price` | numeric(14,2) |  |  |  |
| `on_hand_qty` | integer | yes | 0 |  |
| `reserved_qty` | integer | yes | 0 |  |
| `available_qty` | integer |  |  |  |
| `reorder_level` | integer | yes | 0 |  |
| `max_stock_level` | integer |  |  |  |
| `warranty_days` | integer | yes | 0 |  |
| `batch_no` | varchar(64) |  |  |  |
| `serial_tracked` | boolean | yes | false |  |
| `location` | varchar(64) |  |  |  |
| `first_stocked_at` | timestamptz |  |  |  |
| `last_purchased_at` | timestamptz |  |  |  |
| `last_sold_at` | timestamptz |  |  |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `catalog_component_id` | uuid |  |  | FK → catalog_components.id ON DELETE SET NULL |

<a id="mobistack-public-products"></a>
#### products

A spare part in one shop's stock, not the shared fitment catalog.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `category_id` | uuid | yes |  | FK → categories.id ON DELETE RESTRICT |
| `brand_id` | uuid |  |  | FK → brands.id ON DELETE SET NULL |
| `name` | varchar(200) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `description` | text |  |  |  |
| `hsn_code` | varchar(16) |  |  |  |
| `unit` | varchar(16) | yes | 'PCS' |  |
| `tax_rate` | numeric(5,2) | yes | 0 |  |
| `image_url` | text |  |  |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Shared fitment catalog

- [catalog_brands](#mobistack-public-catalog-brands)
- [catalog_components](#mobistack-public-catalog-components)
- [catalog_contributions](#mobistack-public-catalog-contributions)
- [catalog_contributors](#mobistack-public-catalog-contributors)
- [catalog_device_aliases](#mobistack-public-catalog-device-aliases)
- [catalog_devices](#mobistack-public-catalog-devices)
- [catalog_fitments](#mobistack-public-catalog-fitments)
- [commons_reviewers](#mobistack-public-commons-reviewers)
- [sharing_group_members](#mobistack-public-sharing-group-members)
- [sharing_groups](#mobistack-public-sharing-groups)

<a id="mobistack-public-catalog-brands"></a>
#### catalog_brands

A brand in the shared fitment catalog. Not owned by a shop.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `name` | varchar(80) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `logo_url` | text |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `version` | bigint | yes | 0 |  |

<a id="mobistack-public-catalog-components"></a>
#### catalog_components

A part in the shared fitment catalog, such as a screen for a named phone.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `category_code` | varchar(64) | yes |  |  |
| `name` | varchar(160) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `description` | text |  |  |  |
| `attributes` | jsonb | yes | '{}' |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `version` | bigint | yes | 0 |  |

<a id="mobistack-public-catalog-contributions"></a>
#### catalog_contributions

A proposed fitment, waiting for a commons reviewer.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `kind` | varchar(32) | yes |  |  |
| `target_id` | uuid |  |  |  |
| `payload` | jsonb | yes |  |  |
| `reason` | varchar(500) |  |  |  |
| `status` | varchar(16) | yes | 'PENDING' |  |
| `submitted_by` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `reviewed_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `reviewed_at` | timestamptz |  |  |  |
| `review_note` | varchar(500) |  |  |  |
| `applied_id` | uuid |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `version` | bigint | yes | 0 |  |
| `group_id` | uuid |  |  | FK → sharing_groups.id |

<a id="mobistack-public-catalog-contributors"></a>
#### catalog_contributors

A person or shop allowed to propose fitment rows.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `user_id` | uuid | yes |  | primary key; FK → users.id ON DELETE CASCADE |
| `accepted_count` | integer | yes | 0 |  |
| `rejected_count` | integer | yes | 0 |  |
| `trusted` | boolean | yes | false |  |
| `trusted_at` | timestamptz |  |  |  |
| `trusted_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `banned` | boolean | yes | false |  |
| `banned_reason` | varchar(255) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `version` | bigint | yes | 0 |  |

<a id="mobistack-public-catalog-device-aliases"></a>
#### catalog_device_aliases

Another name for a shared phone.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `device_id` | uuid | yes |  | FK → catalog_devices.id ON DELETE CASCADE |
| `alias` | varchar(120) | yes |  |  |
| `normalized_alias` | text |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-catalog-devices"></a>
#### catalog_devices

A phone in the shared fitment catalog.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `brand_id` | uuid | yes |  | FK → catalog_brands.id ON DELETE CASCADE |
| `name` | varchar(120) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `variant` | varchar(40) |  |  |  |
| `model_code` | varchar(60) |  |  |  |
| `release_year` | integer |  |  |  |
| `lookup_count` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `version` | bigint | yes | 0 |  |

<a id="mobistack-public-catalog-fitments"></a>
#### catalog_fitments

Which shared part fits which shared phone, inside one sharing group.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `component_id` | uuid | yes |  | FK → catalog_components.id ON DELETE CASCADE |
| `device_id` | uuid | yes |  | FK → catalog_devices.id ON DELETE CASCADE |
| `fit_quality` | varchar(24) | yes | 'EXACT' |  |
| `confirmations` | integer | yes | 0 |  |
| `disputes` | integer | yes | 0 |  |
| `verified_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `verified_at` | timestamptz |  |  |  |
| `disputed` | boolean | yes | false |  |
| `contributed_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |
| `version` | bigint | yes | 0 |  |
| `group_id` | uuid |  |  | FK → sharing_groups.id |

<a id="mobistack-public-commons-reviewers"></a>
#### commons_reviewers

A person Prabhix has allowed to review the shared catalog.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `user_id` | uuid | yes |  | primary key; FK → users.id ON DELETE CASCADE |
| `granted_by` | uuid | yes |  |  |
| `granted_at` | timestamptz | yes | now() |  |
| `reason` | varchar(500) |  |  |  |

<a id="mobistack-public-sharing-group-members"></a>
#### sharing_group_members

A shop or a person in a sharing group. Exactly one of shop_id and user_id is set.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `group_id` | uuid | yes |  | FK → sharing_groups.id ON DELETE CASCADE |
| `shop_id` | uuid |  |  | FK → shops.id ON DELETE CASCADE |
| `user_id` | uuid |  |  | FK → users.id ON DELETE CASCADE |
| `role` | varchar(16) | yes |  |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-sharing-groups"></a>
#### sharing_groups

A group of shops that share fitment rows. Stock, sales, and customers stay on the shop.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `name` | varchar(160) | yes |  |  |
| `owner_user_id` | uuid | yes |  | FK → users.id |
| `created_at` | timestamptz | yes | now() |  |

### Shop billing

- [billing_orders](#mobistack-public-billing-orders)
- [billing_plans](#mobistack-public-billing-plans)
- [billing_prices](#mobistack-public-billing-prices)
- [billing_webhook_events](#mobistack-public-billing-webhook-events)
- [plan_features](#mobistack-public-plan-features)

<a id="mobistack-public-billing-orders"></a>
#### billing_orders

A shop's Razorpay order for a plan, an extra screen, or a join fee. amount is rupees. shop_id is the shop. The JSON field on the API is still workspaceId.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `price_code` | varchar(40) | yes |  |  |
| `purpose` | varchar(80) | yes |  |  |
| `amount` | numeric(14,2) | yes |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `status` | varchar(24) | yes |  |  |
| `gateway` | varchar(40) | yes |  |  |
| `gateway_order_id` | varchar(80) |  |  |  |
| `gateway_payment_id` | varchar(80) |  |  |  |
| `entitlement_code` | varchar(40) | yes |  |  |
| `idempotency_key` | varchar(80) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-billing-plans"></a>
#### billing_plans

A plan a shop can buy. amount is rupees. Features are plan_features rows, not a jsonb list.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `code` | varchar(40) | yes |  | unique |
| `name` | varchar(80) | yes |  |  |
| `description` | varchar(255) |  |  |  |
| `active` | boolean | yes | true |  |
| `amount` | numeric(14,2) | yes | 0 |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `interval` | varchar(20) | yes | 'MONTHLY' |  |
| `sort_order` | integer | yes | 0 |  |

<a id="mobistack-public-billing-prices"></a>
#### billing_prices

A MobiStack price point on a plan, in rupees.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `plan_id` | uuid | yes |  | FK → billing_plans.id ON DELETE CASCADE |
| `code` | varchar(40) | yes |  | unique |
| `amount` | numeric(14,2) | yes |  |  |
| `currency` | varchar(3) | yes | 'INR' |  |
| `interval` | varchar(20) | yes |  |  |
| `entitlement` | varchar(40) | yes |  |  |
| `active` | boolean | yes | true |  |

<a id="mobistack-public-billing-webhook-events"></a>
#### billing_webhook_events

A raw Razorpay webhook, stored so the same event is applied once.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `provider` | varchar(40) | yes |  |  |
| `event_id` | varchar(80) | yes |  |  |
| `payload` | jsonb | yes | '{}' |  |
| `processed_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-plan-features"></a>
#### plan_features

Which feature codes a MobiStack plan includes.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `plan_id` | uuid | yes |  | FK → billing_plans.id ON DELETE CASCADE |
| `feature_code` | varchar(40) | yes |  |  |

### Parties

- [customers](#mobistack-public-customers)
- [suppliers](#mobistack-public-suppliers)

<a id="mobistack-public-customers"></a>
#### customers

A person a shop repairs phones for. outstanding_amount is rupees.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `name` | varchar(160) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `phone` | varchar(32) |  |  |  |
| `email` | varchar(255) |  |  |  |
| `address_line1` | varchar(255) |  |  |  |
| `city` | varchar(120) |  |  |  |
| `customer_type` | varchar(20) | yes | 'RETAIL' |  |
| `gst_number` | varchar(20) |  |  |  |
| `credit_limit` | numeric(14,2) | yes | 0 |  |
| `outstanding_amount` | numeric(14,2) | yes | 0 |  |
| `total_purchases` | numeric(14,2) | yes | 0 |  |
| `last_transaction_at` | timestamptz |  |  |  |
| `notes` | text |  |  |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="mobistack-public-suppliers"></a>
#### suppliers

A vendor a shop buys parts from.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `name` | varchar(160) | yes |  |  |
| `normalized_name` | text |  |  |  |
| `contact_person` | varchar(160) |  |  |  |
| `phone` | varchar(32) |  |  |  |
| `email` | varchar(255) |  |  |  |
| `address_line1` | varchar(255) |  |  |  |
| `city` | varchar(120) |  |  |  |
| `state` | varchar(120) |  |  |  |
| `postal_code` | varchar(20) |  |  |  |
| `gst_number` | varchar(20) |  |  |  |
| `payment_terms_days` | integer | yes | 0 |  |
| `opening_balance` | numeric(14,2) | yes | 0 |  |
| `outstanding_amount` | numeric(14,2) | yes | 0 |  |
| `notes` | text |  |  |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Counter

- [payments](#mobistack-public-payments)
- [sale_items](#mobistack-public-sale-items)
- [sales](#mobistack-public-sales)

<a id="mobistack-public-payments"></a>
#### payments

Money in or out against a sale, purchase, repair, or billing row. reference_id is not a foreign key. The type is reference_type.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `reference_type` | varchar(20) | yes |  |  |
| `reference_id` | uuid | yes |  |  |
| `method` | varchar(20) | yes |  |  |
| `amount` | numeric(14,2) | yes |  |  |
| `status` | varchar(24) | yes |  |  |
| `gateway` | varchar(40) |  |  |  |
| `gateway_ref` | varchar(80) |  |  |  |
| `notes` | varchar(255) |  |  |  |
| `occurred_at` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-sale-items"></a>
#### sale_items

A line on a sale.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `sale_id` | uuid | yes |  | FK → sales.id ON DELETE CASCADE |
| `product_variant_id` | uuid | yes |  | FK → product_variants.id ON DELETE RESTRICT |
| `quantity` | integer | yes |  |  |
| `unit_price` | numeric(14,2) | yes |  |  |
| `unit_cost` | numeric(14,2) | yes | 0 |  |
| `discount` | numeric(14,2) | yes | 0 |  |
| `tax_rate` | numeric(6,2) | yes | 0 |  |
| `line_total` | numeric(14,2) | yes |  |  |
| `profit` | numeric(14,2) | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-sales"></a>
#### sales

A counter sale. Amounts are rupees.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `customer_id` | uuid |  |  | FK → customers.id ON DELETE SET NULL |
| `invoice_number` | varchar(32) | yes |  |  |
| `status` | varchar(20) | yes |  |  |
| `pricing_flag` | varchar(20) | yes | 'NORMAL' |  |
| `subtotal` | numeric(14,2) | yes | 0 |  |
| `discount` | numeric(14,2) | yes | 0 |  |
| `tax` | numeric(14,2) | yes | 0 |  |
| `total` | numeric(14,2) | yes | 0 |  |
| `paid` | numeric(14,2) | yes | 0 |  |
| `outstanding` | numeric(14,2) | yes | 0 |  |
| `profit` | numeric(14,2) | yes | 0 |  |
| `notes` | text |  |  |  |
| `idempotency_key` | varchar(80) |  |  |  |
| `device_id` | varchar(80) |  |  |  |
| `occurred_at` | timestamptz | yes | now() |  |
| `voided_at` | timestamptz |  |  |  |
| `void_reason` | varchar(255) |  |  |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Repairs

- [repair_parts](#mobistack-public-repair-parts)
- [repairs](#mobistack-public-repairs)

<a id="mobistack-public-repair-parts"></a>
#### repair_parts

A part used on a repair job.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `repair_id` | uuid | yes |  | FK → repairs.id ON DELETE CASCADE |
| `product_variant_id` | uuid | yes |  | FK → product_variants.id ON DELETE RESTRICT |
| `quantity` | integer | yes |  |  |
| `unit_price` | numeric(14,2) | yes |  |  |
| `unit_cost` | numeric(14,2) | yes | 0 |  |
| `line_total` | numeric(14,2) | yes |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-repairs"></a>
#### repairs

A repair job. Amounts are rupees.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `customer_id` | uuid |  |  | FK → customers.id ON DELETE SET NULL |
| `device_model_id` | uuid |  |  | FK → device_models.id ON DELETE SET NULL |
| `technician_user_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `job_number` | varchar(32) | yes |  |  |
| `imei` | varchar(32) |  |  |  |
| `problem` | text | yes |  |  |
| `status` | varchar(24) | yes |  |  |
| `estimated_cost` | numeric(14,2) | yes | 0 |  |
| `labor_charge` | numeric(14,2) | yes | 0 |  |
| `labor_cost` | numeric(14,2) | yes | 0 |  |
| `parts_total` | numeric(14,2) | yes | 0 |  |
| `parts_cost` | numeric(14,2) | yes | 0 |  |
| `total` | numeric(14,2) | yes | 0 |  |
| `paid` | numeric(14,2) | yes | 0 |  |
| `outstanding` | numeric(14,2) | yes | 0 |  |
| `profit` | numeric(14,2) | yes | 0 |  |
| `customer_notes` | text |  |  |  |
| `internal_notes` | text |  |  |  |
| `expected_at` | timestamptz |  |  |  |
| `delivered_at` | timestamptz |  |  |  |
| `idempotency_key` | varchar(80) |  |  |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Purchasing

- [purchase_items](#mobistack-public-purchase-items)
- [purchases](#mobistack-public-purchases)

<a id="mobistack-public-purchase-items"></a>
#### purchase_items

A line on a purchase.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `purchase_id` | uuid | yes |  | FK → purchases.id ON DELETE CASCADE |
| `product_variant_id` | uuid | yes |  | FK → product_variants.id ON DELETE RESTRICT |
| `quantity` | integer | yes |  |  |
| `unit_cost` | numeric(14,2) | yes |  |  |
| `line_total` | numeric(14,2) | yes |  |  |
| `batch_no` | varchar(40) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-purchases"></a>
#### purchases

A purchase from a supplier. Amounts are rupees.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `supplier_id` | uuid | yes |  | FK → suppliers.id ON DELETE RESTRICT |
| `status` | varchar(20) | yes |  |  |
| `subtotal` | numeric(14,2) | yes | 0 |  |
| `tax` | numeric(14,2) | yes | 0 |  |
| `total` | numeric(14,2) | yes | 0 |  |
| `paid` | numeric(14,2) | yes | 0 |  |
| `outstanding` | numeric(14,2) | yes | 0 |  |
| `notes` | text |  |  |  |
| `idempotency_key` | varchar(80) |  |  |  |
| `received_at` | timestamptz | yes | now() |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Stock

- [inventory_transactions](#mobistack-public-inventory-transactions)
- [stock_alerts](#mobistack-public-stock-alerts)

<a id="mobistack-public-inventory-transactions"></a>
#### inventory_transactions

A stock movement. balance_after is the quantity after the movement. Costs are rupees.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `product_variant_id` | uuid | yes |  | FK → product_variants.id ON DELETE CASCADE |
| `type` | varchar(20) | yes |  |  |
| `quantity` | integer | yes |  |  |
| `on_hand_delta` | integer | yes |  |  |
| `reserved_delta` | integer | yes | 0 |  |
| `balance_after` | integer | yes |  |  |
| `unit_cost` | numeric(14,2) |  |  |  |
| `total_cost` | numeric(14,2) |  |  |  |
| `reference_type` | varchar(24) | yes | 'MANUAL' |  |
| `reference_id` | uuid |  |  |  |
| `reference_label` | varchar(80) |  |  |  |
| `idempotency_key` | varchar(120) |  |  |  |
| `device_id` | varchar(120) |  |  |  |
| `batch_no` | varchar(64) |  |  |  |
| `serial_no` | varchar(120) |  |  |  |
| `reason` | varchar(160) |  |  |  |
| `notes` | text |  |  |  |
| `occurred_at` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `created_by_name` | varchar(160) |  |  |  |

<a id="mobistack-public-stock-alerts"></a>
#### stock_alerts

An open low-stock or ageing alert on a variant.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `product_variant_id` | uuid | yes |  | FK → product_variants.id ON DELETE CASCADE |
| `alert_type` | varchar(24) | yes |  |  |
| `severity` | varchar(12) | yes | 'ORANGE' |  |
| `status` | varchar(16) | yes | 'OPEN' |  |
| `threshold_value` | integer |  |  |  |
| `observed_value` | integer |  |  |  |
| `message` | varchar(400) | yes |  |  |
| `acknowledged_at` | timestamptz |  |  |  |
| `acknowledged_by` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `resolved_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |

### Pricing

- [price_list_items](#mobistack-public-price-list-items)
- [price_lists](#mobistack-public-price-lists)
- [price_rules](#mobistack-public-price-rules)

<a id="mobistack-public-price-list-items"></a>
#### price_list_items

A variant's price on a price list, in rupees.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `price_list_id` | uuid | yes |  | FK → price_lists.id ON DELETE CASCADE |
| `product_variant_id` | uuid | yes |  | FK → product_variants.id ON DELETE CASCADE |
| `price` | numeric(14,2) | yes |  |  |
| `min_quantity` | integer | yes | 1 |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-price-lists"></a>
#### price_lists

A named price list for a shop.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `code` | varchar(48) | yes |  |  |
| `name` | varchar(120) | yes |  |  |
| `pricing_flag` | varchar(20) |  |  |  |
| `customer_type` | varchar(20) |  |  |  |
| `priority` | integer | yes | 100 |  |
| `valid_from` | timestamptz |  |  |  |
| `valid_to` | timestamptz |  |  |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="mobistack-public-price-rules"></a>
#### price_rules

A rule that adjusts a price, in rupees or as a percentage.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `name` | varchar(120) | yes |  |  |
| `description` | varchar(255) |  |  |  |
| `priority` | integer | yes | 100 |  |
| `scope_type` | varchar(20) | yes | 'ALL' |  |
| `scope_id` | uuid |  |  |  |
| `pricing_flag` | varchar(20) |  |  |  |
| `customer_type` | varchar(20) |  |  |  |
| `transaction_type` | varchar(20) |  |  |  |
| `min_quantity` | integer |  |  |  |
| `min_stock_age_days` | integer |  |  |  |
| `supplier_id` | uuid |  |  | FK → suppliers.id ON DELETE CASCADE |
| `strategy` | varchar(24) | yes |  |  |
| `base_field` | varchar(20) | yes | 'RETAIL_PRICE' |  |
| `amount` | numeric(14,2) |  |  |  |
| `percentage` | numeric(6,3) |  |  |  |
| `respect_min_price` | boolean | yes | true |  |
| `valid_from` | timestamptz |  |  |  |
| `valid_to` | timestamptz |  |  |  |
| `active` | boolean | yes | true |  |
| `version` | bigint | yes | 0 |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

### Notifications

- [inbox_notifications](#mobistack-public-inbox-notifications)
- [notification_outbox](#mobistack-public-notification-outbox)
- [notification_preferences](#mobistack-public-notification-preferences)
- [push_devices](#mobistack-public-push-devices)

<a id="mobistack-public-inbox-notifications"></a>
#### inbox_notifications

An in-app notification for a shop user.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid |  |  | FK → shops.id ON DELETE SET NULL |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `event_type` | varchar(40) | yes |  |  |
| `title` | varchar(200) | yes |  |  |
| `body` | text |  |  |  |
| `link` | varchar(400) |  |  |  |
| `read_at` | timestamptz |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

<a id="mobistack-public-notification-outbox"></a>
#### notification_outbox

A notification waiting to be delivered on a channel.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid |  |  | FK → shops.id ON DELETE CASCADE |
| `user_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `event_type` | varchar(40) | yes |  |  |
| `channel` | varchar(20) | yes |  |  |
| `recipient` | varchar(255) |  |  |  |
| `subject` | varchar(255) |  |  |  |
| `body` | text | yes |  |  |
| `status` | varchar(20) | yes |  |  |
| `provider` | varchar(40) |  |  |  |
| `provider_ref` | varchar(80) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `sent_at` | timestamptz |  |  |  |

<a id="mobistack-public-notification-preferences"></a>
#### notification_preferences

Which channels a person wants.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `event_type` | varchar(40) | yes |  |  |
| `email` | boolean | yes | true |  |
| `whatsapp` | boolean | yes | false |  |
| `push` | boolean | yes | true |  |
| `sms` | boolean | yes | false |  |

<a id="mobistack-public-push-devices"></a>
#### push_devices

A shop user's device registered for push.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `shop_id` | uuid |  |  | FK → shops.id ON DELETE SET NULL |
| `device_id` | varchar(80) | yes |  |  |
| `platform` | varchar(20) | yes |  |  |
| `expo_push_token` | varchar(240) |  |  |  |
| `app_version` | varchar(40) |  |  |  |
| `native_build` | integer |  |  |  |
| `last_seen_at` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `last_error` | varchar(200) |  |  |  |
| `retired_at` | timestamptz |  |  |  |

### Support

- [support_conversations](#mobistack-public-support-conversations)
- [support_messages](#mobistack-public-support-messages)

<a id="mobistack-public-support-conversations"></a>
#### support_conversations

A support thread between a shop and Prabhix.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid |  |  | FK → shops.id ON DELETE SET NULL |
| `user_id` | uuid | yes |  | FK → users.id ON DELETE CASCADE |
| `subject` | varchar(200) | yes |  |  |
| `status` | varchar(20) | yes | 'OPEN' |  |
| `channel` | varchar(20) | yes | 'WEB' |  |
| `assigned_to` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `last_message_at` | timestamptz | yes | now() |  |
| `created_at` | timestamptz | yes | now() |  |
| `updated_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
| `updated_by` | uuid |  |  |  |

<a id="mobistack-public-support-messages"></a>
#### support_messages

A message in that support thread.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `conversation_id` | uuid | yes |  | FK → support_conversations.id ON DELETE CASCADE |
| `author_type` | varchar(12) | yes |  |  |
| `user_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `body` | text | yes |  |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |

### Other

- [app_releases](#mobistack-public-app-releases)
- [audit_logs](#mobistack-public-audit-logs)
- [feature_flags](#mobistack-public-feature-flags)
- [import_jobs](#mobistack-public-import-jobs)

<a id="mobistack-public-app-releases"></a>
#### app_releases

The minimum and latest native build the shop app should run.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `platform` | varchar(20) | yes |  | unique |
| `min_native_build` | integer | yes | 1 |  |
| `latest_native_build` | integer | yes | 1 |  |
| `ota_channel` | varchar(40) | yes | 'production' |  |
| `ota_runtime_version` | varchar(40) |  |  |  |
| `force_native_update` | boolean | yes | false |  |
| `store_url` | varchar(400) |  |  |  |
| `notes` | text |  |  |  |
| `updated_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-audit-logs"></a>
#### audit_logs

Append-only record of a shop change. Separate from oneOps audit_logs.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `user_id` | uuid |  |  | FK → users.id ON DELETE SET NULL |
| `actor_name` | varchar(160) |  |  |  |
| `action` | varchar(64) | yes |  |  |
| `entity_type` | varchar(64) | yes |  |  |
| `entity_id` | uuid |  |  |  |
| `summary` | text | yes |  |  |
| `before_data` | jsonb |  |  |  |
| `after_data` | jsonb |  |  |  |
| `ip_address` | varchar(64) |  |  |  |
| `created_at` | timestamptz | yes | now() |  |

<a id="mobistack-public-feature-flags"></a>
#### feature_flags

A flag for one shop.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid |  |  | FK → shops.id ON DELETE CASCADE |
| `code` | varchar(40) | yes |  |  |
| `enabled` | boolean | yes | false |  |

<a id="mobistack-public-import-jobs"></a>
#### import_jobs

A spreadsheet import and its result.

| Column | Type | Required | Default | Detail |
|---|---|---|---|---|
| `id` | uuid | yes | gen_random_uuid() | primary key |
| `shop_id` | uuid | yes |  | FK → shops.id ON DELETE CASCADE |
| `kind` | varchar(40) | yes |  |  |
| `status` | varchar(20) | yes |  |  |
| `source_name` | varchar(160) |  |  |  |
| `result_json` | jsonb | yes | '{}' |  |
| `created_at` | timestamptz | yes | now() |  |
| `created_by` | uuid |  |  |  |
