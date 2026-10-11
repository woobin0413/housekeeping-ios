begin;

alter table public.photo_analyses drop constraint photo_analyses_state_check;
alter table public.photo_analyses drop constraint photo_analyses_check;
alter table public.photo_analyses add column failure_code text;
alter table public.photo_analyses add constraint photo_analyses_state_check
  check (state in ('PROCESSING', 'SUGGESTED', 'UNRECOGNIZED', 'RETRY_REQUIRED', 'FAILED'));
alter table public.photo_analyses add constraint photo_analyses_result_check check (
  (state = 'PROCESSING' and suggestion is null and reason is null and failure_code is null)
  or (state = 'SUGGESTED' and suggestion is not null and reason is null and failure_code is null)
  or (state = 'UNRECOGNIZED' and suggestion is null and reason is not null and failure_code is null)
  or (
    state = 'RETRY_REQUIRED' and suggestion is null and reason is null
    and (failure_code is null or failure_code in ('PROVIDER_UNAVAILABLE', 'PROVIDER_TIMEOUT'))
  )
  or (
    state = 'FAILED' and suggestion is null and reason is null
    and failure_code in ('PROVIDER_REFUSAL', 'INVALID_PROVIDER_RESPONSE')
  )
);

create function private.input_recognition_usage(p_value jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  input_tokens numeric;
  output_tokens numeric;
  total_tokens numeric;
  response_id text;
begin
  perform private.validate_keys(
    p_value,
    array['inputTokens', 'outputTokens', 'totalTokens', 'providerResponseId'],
    array['inputTokens', 'outputTokens', 'totalTokens', 'providerResponseId']
  );
  if jsonb_typeof(p_value->'inputTokens') <> 'number'
      or jsonb_typeof(p_value->'outputTokens') <> 'number'
      or jsonb_typeof(p_value->'totalTokens') <> 'number'
      or jsonb_typeof(p_value->'providerResponseId') <> 'string' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  input_tokens := (p_value->>'inputTokens')::numeric;
  output_tokens := (p_value->>'outputTokens')::numeric;
  total_tokens := (p_value->>'totalTokens')::numeric;
  response_id := p_value->>'providerResponseId';
  if input_tokens < 0 or output_tokens < 0 or total_tokens < 0
      or input_tokens > 1000000000 or output_tokens > 1000000000
      or total_tokens > 1000000000
      or trunc(input_tokens) <> input_tokens or trunc(output_tokens) <> output_tokens
      or trunc(total_tokens) <> total_tokens or total_tokens <> input_tokens + output_tokens
      or char_length(response_id) not between 1 and 200 then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  return jsonb_build_object(
    'inputTokens', input_tokens::bigint,
    'outputTokens', output_tokens::bigint,
    'totalTokens', total_tokens::bigint,
    'providerResponseId', response_id
  );
exception when invalid_text_representation or numeric_value_out_of_range then
  raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
end;
$$;

create function private.input_recognition_suggestion(p_value jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  key text;
  value text;
  result jsonb := '{}'::jsonb;
begin
  perform private.validate_keys(
    p_value,
    array['name', 'description', 'brand', 'model'],
    array['name', 'description', 'brand', 'model']
  );
  foreach key in array array['name', 'description', 'brand', 'model'] loop
    if jsonb_typeof(p_value->key) = 'null' and key <> 'name' then
      result := result || jsonb_build_object(key, null);
      continue;
    end if;
    if jsonb_typeof(p_value->key) <> 'string' then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
    value := p_value->>key;
    if value <> btrim(value) or char_length(value) < 1
        or char_length(value) > (case when key = 'name' then 200
          when key = 'description' then 2000 else 100 end) then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
    result := result || jsonb_build_object(key, value);
  end loop;
  return result;
end;
$$;

create or replace function private.recognition_result(p_analysis public.photo_analyses)
returns jsonb language plpgsql stable set search_path = '' as $$
begin
  if p_analysis.state = 'SUGGESTED' then
    return jsonb_build_object(
      'status', 'SUGGESTED', 'analysisId', p_analysis.id,
      'photoId', p_analysis.photo_id, 'suggestion', p_analysis.suggestion
    );
  end if;
  if p_analysis.state = 'UNRECOGNIZED' then
    return jsonb_build_object(
      'status', 'UNRECOGNIZED', 'analysisId', p_analysis.id,
      'photoId', p_analysis.photo_id, 'suggestion', null, 'reason', p_analysis.reason
    );
  end if;
  if p_analysis.state = 'FAILED' then
    return jsonb_build_object(
      'status', 'FAILED', 'analysisId', p_analysis.id,
      'photoId', p_analysis.photo_id, 'failureCode', p_analysis.failure_code
    );
  end if;
  if p_analysis.state = 'RETRY_REQUIRED' then
    return jsonb_strip_nulls(jsonb_build_object(
      'status', 'RETRY_REQUIRED', 'analysisId', p_analysis.id,
      'photoId', p_analysis.photo_id, 'failureCode', p_analysis.failure_code
    ));
  end if;
  return jsonb_build_object(
    'status', 'IN_FLIGHT', 'analysisId', p_analysis.id, 'photoId', p_analysis.photo_id
  );
end;
$$;

create function public.finish_recognition(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  analysis_id uuid;
  photo_id uuid;
  output_state text;
  output_suggestion jsonb;
  output_reason text;
  provider text;
  model text;
  prompt text;
  usage jsonb;
  analysis public.photo_analyses;
begin
  perform private.validate_keys(
    p_input,
    array['analysisId', 'photoId', 'state', 'suggestion', 'reason',
      'providerId', 'modelId', 'promptVersion', 'consumption'],
    array['analysisId', 'photoId', 'state', 'suggestion', 'reason',
      'providerId', 'modelId', 'promptVersion', 'consumption']
  );
  analysis_id := private.input_uuid(p_input->'analysisId');
  photo_id := private.input_uuid(p_input->'photoId');
  if jsonb_typeof(p_input->'state') <> 'string'
      or p_input->>'state' not in ('SUGGESTED', 'UNRECOGNIZED') then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  output_state := p_input->>'state';
  if output_state = 'SUGGESTED' then
    output_suggestion := private.input_recognition_suggestion(p_input->'suggestion');
    if jsonb_typeof(p_input->'reason') <> 'null' then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
  else
    if jsonb_typeof(p_input->'suggestion') <> 'null'
        or jsonb_typeof(p_input->'reason') <> 'string'
        or p_input->>'reason' not in ('UNCLEAR_IMAGE', 'MULTIPLE_PRODUCTS', 'NO_PRODUCT') then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
    output_reason := p_input->>'reason';
  end if;
  provider := p_input->>'providerId';
  model := p_input->>'modelId';
  prompt := p_input->>'promptVersion';
  if jsonb_typeof(p_input->'providerId') <> 'string'
      or jsonb_typeof(p_input->'modelId') <> 'string'
      or jsonb_typeof(p_input->'promptVersion') <> 'string'
      or char_length(provider) not between 1 and 100
      or char_length(model) not between 1 and 200
      or char_length(prompt) not between 1 and 100 then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  usage := private.input_recognition_usage(p_input->'consumption');

  select * into analysis from public.photo_analyses where id = analysis_id for update;
  if not found or analysis.photo_id <> photo_id then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  perform 1 from public.household_members
    where household_id = analysis.household_id and user_id = analysis.requested_by for share;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;

  if analysis.state in ('SUGGESTED', 'UNRECOGNIZED') then
    if analysis.state <> output_state or analysis.suggestion is distinct from output_suggestion
        or analysis.reason is distinct from output_reason
        or analysis.provider_id is distinct from provider
        or analysis.model_id is distinct from model
        or analysis.prompt_version is distinct from prompt
        or analysis.consumption is distinct from usage then
      raise sqlstate 'PT409' using message = 'CONFLICT';
    end if;
    return private.recognition_result(analysis);
  end if;
  if analysis.state <> 'PROCESSING' or analysis.lease_expires_at <= statement_timestamp() then
    raise sqlstate 'PT409' using message = 'CONFLICT';
  end if;

  update public.photo_analyses set
    state = output_state,
    suggestion = output_suggestion,
    reason = output_reason,
    provider_id = provider,
    model_id = model,
    prompt_version = prompt,
    consumption = usage,
    updated_at = clock_timestamp()
    where id = analysis.id returning * into analysis;
  return private.recognition_result(analysis);
end;
$$;

create function public.fail_recognition(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  analysis_id uuid;
  photo_id uuid;
  failure text;
  failure_state text;
  analysis public.photo_analyses;
begin
  perform private.validate_keys(
    p_input,
    array['analysisId', 'photoId', 'failureCode'],
    array['analysisId', 'photoId', 'failureCode']
  );
  analysis_id := private.input_uuid(p_input->'analysisId');
  photo_id := private.input_uuid(p_input->'photoId');
  if jsonb_typeof(p_input->'failureCode') <> 'string'
      or p_input->>'failureCode' not in (
        'PROVIDER_REFUSAL', 'INVALID_PROVIDER_RESPONSE',
        'PROVIDER_UNAVAILABLE', 'PROVIDER_TIMEOUT'
      ) then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  failure := p_input->>'failureCode';
  failure_state := case when failure in ('PROVIDER_REFUSAL', 'INVALID_PROVIDER_RESPONSE')
    then 'FAILED' else 'RETRY_REQUIRED' end;

  select * into analysis from public.photo_analyses where id = analysis_id for update;
  if not found or analysis.photo_id <> photo_id then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  perform 1 from public.household_members
    where household_id = analysis.household_id and user_id = analysis.requested_by for share;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  if analysis.state = failure_state and analysis.failure_code = failure then
    return private.recognition_result(analysis);
  end if;
  if analysis.state <> 'PROCESSING' then
    raise sqlstate 'PT409' using message = 'CONFLICT';
  end if;
  update public.photo_analyses set
    state = failure_state,
    failure_code = failure,
    updated_at = clock_timestamp()
    where id = analysis.id returning * into analysis;
  return private.recognition_result(analysis);
end;
$$;

revoke all on function private.input_recognition_usage(jsonb),
  private.input_recognition_suggestion(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.finish_recognition(jsonb), public.fail_recognition(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.finish_recognition(jsonb), public.fail_recognition(jsonb)
  to service_role;

commit;
