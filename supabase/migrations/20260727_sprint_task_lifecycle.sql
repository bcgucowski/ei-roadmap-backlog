alter table public.dev_tasks
  add column if not exists sprint_id bigint references public.sprints(id) on delete set null;

create index if not exists dev_tasks_sprint_id_idx
  on public.dev_tasks(sprint_id);

-- Existing open activities belong to the sprint currently assigned to the requirement.
update public.dev_tasks dt
set sprint_id = r.sprint_id
from public.roadmap r
where r.id = dt.roadmap_id
  and dt.status <> 'Close'
  and dt.sprint_id is null
  and r.sprint_id is not null;

create or replace function public.move_requirement_sprint(
  p_roadmap_id bigint,
  p_target_sprint_id bigint,
  p_mode text default 'simple',
  p_set_dev_backlog boolean default false
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_source_sprint_id bigint;
  v_target_start date;
  v_target_end date;
  v_task public.dev_tasks%rowtype;
  v_activities integer := 0;
  v_reason text;
begin
  select sprint_id
    into v_source_sprint_id
  from public.roadmap
  where id = p_roadmap_id
  for update;

  if not found then
    raise exception 'Requirement % not found', p_roadmap_id;
  end if;

  if p_target_sprint_id is null then
    v_reason := 'Requirement returned to backlog queue.';

    update public.dev_tasks
    set status = 'Close',
        closed_date = current_date,
        comments = concat_ws(E'\n', nullif(comments, ''), v_reason)
    where roadmap_id = p_roadmap_id
      and status <> 'Close';
    get diagnostics v_activities = row_count;

    update public.roadmap
    set sprint_id = null,
        status = case when p_set_dev_backlog then 'Dev Backlog' else status end
    where id = p_roadmap_id;

    return jsonb_build_object(
      'mode', 'backlog',
      'activities_closed', v_activities,
      'status_set_to_dev_backlog', p_set_dev_backlog
    );
  end if;

  if not exists (select 1 from public.sprints where id = p_target_sprint_id) then
    raise exception 'Sprint % not found', p_target_sprint_id;
  end if;

  if v_source_sprint_id is null or v_source_sprint_id = p_target_sprint_id then
    update public.roadmap
    set sprint_id = p_target_sprint_id
    where id = p_roadmap_id;

    update public.dev_tasks
    set sprint_id = p_target_sprint_id
    where roadmap_id = p_roadmap_id
      and status <> 'Close'
      and sprint_id is null;

    return jsonb_build_object('mode', 'simple', 'activities_updated', 0);
  end if;

  if p_mode not in ('transfer', 'rollover') then
    raise exception 'Mode must be transfer or rollover when changing sprints';
  end if;

  select start_date, end_date
    into v_target_start, v_target_end
  from public.sprints
  where id = p_target_sprint_id;

  for v_task in
    select *
    from public.dev_tasks
    where roadmap_id = p_roadmap_id
      and status <> 'Close'
      and (sprint_id = v_source_sprint_id or sprint_id is null)
    order by id
  loop
    if p_mode = 'transfer' then
      delete from public.dev_tasks where id = v_task.id;
      v_reason := 'Activity transferred from sprint ' || v_source_sprint_id ||
                  ' to sprint ' || p_target_sprint_id || '.';
    else
      v_reason := 'Activity closed at sprint rollover; development continues in sprint ' ||
                  p_target_sprint_id || '.';
      update public.dev_tasks
      set status = 'Close',
          closed_date = current_date,
          comments = concat_ws(E'\n', nullif(comments, ''), v_reason)
      where id = v_task.id;
    end if;

    insert into public.dev_tasks (
      roadmap_id, developer_id, status, percent_completed, complexity, size,
      percent_allocation, effort, start_date, end_date, comments, closed_date,
      sprint_id
    ) values (
      v_task.roadmap_id,
      v_task.developer_id,
      v_task.status,
      case when p_mode = 'rollover' then 0 else v_task.percent_completed end,
      v_task.complexity,
      v_task.size,
      v_task.percent_allocation,
      v_task.effort,
      v_target_start,
      v_target_end,
      concat_ws(E'\n', nullif(v_task.comments, ''), v_reason),
      null,
      p_target_sprint_id
    );
    v_activities := v_activities + 1;
  end loop;

  update public.roadmap
  set sprint_id = p_target_sprint_id
  where id = p_roadmap_id;

  return jsonb_build_object(
    'mode', p_mode,
    'activities_recreated', v_activities,
    'source_sprint_id', v_source_sprint_id,
    'target_sprint_id', p_target_sprint_id
  );
end;
$$;

grant execute on function public.move_requirement_sprint(bigint, bigint, text, boolean)
  to anon, authenticated;
