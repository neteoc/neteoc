-- Cover the audit actor foreign key for later Auth-user offboarding checks.
create index audit_events_actor_user_id_idx
  on app_private.audit_events (actor_user_id);
