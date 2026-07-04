# Prod state snapshot — trltcyzskmcveuabypat — 2026-07-02

Taken before migration-history reconciliation (branching-preview-plan Phase 0).
Restore source for `supabase_migrations.schema_migrations` if repair misfires.

## Applied migration history (86 versions)

```
20260512000000  reporting_pipeline_foundation
20260513000000  reporting_pipeline_owners_and_columns
20260514120000  add_outreach_exclusion_to_sdr_contacts
20260515000000  reporting_pipeline_probability
20260515120000  reporting_pipeline_recent_changes
20260515150000  reporting_pipeline_hourly_sync
20260518000000  reporting_engagements_foundation
20260518010000  reporting_engagements_hourly_sync
20260518020000  reporting_owner_activity_rpc
20260518030000  reporting_owner_performance_rpc
20260520120000  ssg_engagements_foundation
20260523000000  reporting_dataset_registry
20260523120000  ssg_advisors
20260528000000  reporting_refresh_scheduler
20260528120000  custom_field_library
20260528130000  project_custom_fields
20260529120000  project_field_aggregations
20260601000000  release_notes
20260602000000  assessment_leads
20260602120000  tighten_task_custom_field_values_rls
20260603120000  extend_task_source_types_for_ssg
20260604120000  task_project_memberships
20260604130000  task_priority_optional
20260604140000  tpm_backfill_for_board_read
20260605120000  ssg_engagement_contacts
20260605130000  ssg_calendar_events
20260605140000  ssg_calendar_cron
20260605150000  ssg_meetings_fathom_fields
20260606120000  ssg_emails
20260606130000  pinned_items
20260606140000  ssg_firm_partner_visibility
20260606160000  grant_partner_ssg_view_own_firm
20260606170000  ssg_email_cron
20260607120000  tasks_read_via_project_membership
20260607140000  ssg_advisor_membership_access
20260608120000  ssg_meeting_transcript
20260609000000  tas_bdr_foundation
20260609010000  tas_bdr_desk_registration
20260609120000  tasks_rls_shared_access_model
20260609130000  ssg_insights
20260609140000  ssg_fathom_sync_cron
20260609150000  ssg_meeting_transcript_resweep
20260610000000  tas_advance_sequence_fn
20260610000001  tas_consultant_profiles
20260610120000  ssg_advisors_membership_read
20260610121000  ssg_delete_engagement_fn
20260610130000  oauth_as
20260611000001  tas_bdr_desk_icon
20260611000002  tas_inmail_subject
20260611120000  ssg_meetings_source
20260611130000  mcp_admin_connections
20260612000000  tas_assessment_tools_desk_registration
20260612120000  user_home_layouts
20260613120000  prep_calendar_events
20260618120000  project_external_share
20260618130000  project_color_and_favorite_sort
20260618131000  project_external_share_comments
20260618140000  backfill_task_project_memberships
20260618150000  software_tracker_foundation
20260618160000  software_catalog_expansion
20260618180000  software_catalog_fixups
20260618220000  account_merge_completeness
20260619000000  tas_icp_track_nullable
20260619120000  ssg_engagement_relationship_manager_and_notes
20260619130000  ssg_meeting_host_and_prep_superiors
20260619140000  inbox_task_links_to_tasks_route
20260619150000  prep_reminder_preferences_and_digest_cron
20260621120000  prep_auto_sync_optin_and_calendar_cron
20260621130000  organizations_archive_columns
20260622120000  dedupe_tasks_system_views
20260622130000  prep_briefs_cache
20260622140000  storage_logos_avatars_select_policies
20260623000000  transition_assessment_submissions
20260623010000  tas_queue_status_and_referral_tier
20260623020000  tas_import_logs
20260625000000  tas_import_log_id
20260625000001  tas_undo_import_fn
20260626120000  job_descriptions_foundation
20260628120000  work_rail_realtime_publication
20260630120000  (null name — training_library_foundation)
20260630130000  training_resources
20260630170000  ssg_fathom_backfill_cron
20260630180000  avatars_admin_write_policies
20260630200000  business_planning_foundation
20260701000000  business_plan_revenue_drivers
20260701120000  software_manage_grants
```

NOTE: plan said 85 applied; prod moved between 7/01 investigation and 7/02 execution —
training_library_foundation, training_resources, ssg_fathom_backfill_cron,
avatars_admin_write_policies, business_planning_foundation, business_plan_revenue_drivers,
software_manage_grants now applied. Both version-collision partners are applied → archived
by the squash; collisions self-resolve as planned.

## Pending (repo files NOT in prod history) — 9 files

```
20260629120000_hris_foundation.sql
20260629121000_hris_timeoff.sql
20260629122000_hris_onboarding.sql
20260629122500_hris_start_checklist_rpc.sql
20260629123000_hris_comp_benefits.sql
20260630120000_hris_custom_fields.sql          (version shared w/ applied training_library_foundation)
20260630130000_hris_employee_number_default.sql (version shared w/ applied training_resources)
20260630140000_hris_leave_action_tokens.sql
20260630190000_onboarding_checklists_reporting.sql
```

## Storage buckets (8)

| id | public | size limit | mime types |
|----|--------|-----------|------------|
| avatars | true | – | – |
| diagtest | true | – | – |
| documents | false | 52428800 | pdf, word, excel, ppt, jpeg, png, gif, webp, txt, csv |
| logos | true | – | – |
| partner-contracts | false | – | – |
| project-resources | false | – | – |
| task-attachments | false | – | – |
| training-resources | true | – | – |

## Cron jobs (9) — deliberately NOT replayed on branches

| jobid | name | schedule |
|-------|------|----------|
| 3 | geocode-firms-hourly | 0 * * * * |
| 4 | hubspot-sync-ownership-auto | */5 * * * * |
| 8 | reporting-dispatch-due-syncs | * * * * * |
| 9 | ssg-sync-calendar-15min | */15 * * * * |
| 10 | ssg-sync-email-30min | */30 * * * * |
| 11 | ssg-sync-fathom-30min | */30 * * * * |
| 12 | prep-dispatch-due-digests | * * * * * |
| 13 | prep-sync-calendar-15min | */15 * * * * |
| 15 | ssg-fathom-backfill-6h | 15 */6 * * * |

## supabase_realtime publication tables (5)

public.project_favorites, public.project_sections, public.projects,
public.task_project_memberships, public.tasks

## Storage policies (25 on storage.objects)

Captured 2026-07-02 from pg_policies; recreated by the consolidated
`storage_policies` migration. diagtest bucket has no policies (intentional).
