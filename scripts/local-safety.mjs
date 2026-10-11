import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

export const project = 'housekeeping-local';
export const database = `supabase_db_${project}`;

export async function authorizeDockerMutation(method, rawPath, body, inspect) {
  if (method === 'GET' || method === 'HEAD') return;
  const url = new URL(rawPath,'http://docker');
  const path = url.pathname.replace(/^\/v[0-9.]+/,'');
  const ownedContainer = async id => {
    const container=await inspect(`/containers/${encodeURIComponent(decodeURIComponent(id))}/json`);
    assert.equal(container.Config.Labels?.['com.supabase.cli.project'],project,'Refuse another container');
  };
  if(method==='POST' && path==='/containers/create') { loopbackCreate(body); return; }
  const container=path.match(/^\/containers\/([^/]+)(?:\/(start|stop|kill|wait|attach|resize|exec|archive))?$/);
  if(container && ((method==='POST' && container[2]) || (method==='PUT' && container[2]==='archive') || (method==='DELETE' && !container[2]))) {
    await ownedContainer(container[1]); return;
  }
  const execution=path.match(/^\/exec\/([^/]+)\/(start|resize)$/);
  if(method==='POST' && execution) {
    const exec=await inspect(`/exec/${encodeURIComponent(decodeURIComponent(execution[1]))}/json`);
    await ownedContainer(exec.ContainerID); return;
  }
  if(method==='POST' && path==='/networks/create') {
    assert.equal(body.Name,`supabase_network_${project}`);
    assert.equal(body.Labels?.['com.supabase.cli.project'],project);
    return;
  }
  if(method==='POST' && path==='/volumes/create') {
    assert.equal(body.Labels?.['com.supabase.cli.project'],project);
    assert.match(body.Name,/^supabase_[a-z_]+_housekeeping-local$/);
    return;
  }
  const network=path.match(/^\/networks\/([^/]+)(?:\/(connect|disconnect))?$/);
  if(network && (method==='POST' || method==='DELETE')) {
    const value=await inspect(`/networks/${encodeURIComponent(decodeURIComponent(network[1]))}`);
    assert.equal(value.Name,`supabase_network_${project}`);
    for(const id of Object.keys(value.Containers ?? {})) await ownedContainer(id);
    if(method==='POST') {
      assert(network[2]); await ownedContainer(body.Container);
    } else assert(!network[2]);
    return;
  }
  if(method==='POST' && path==='/images/create') {
    assert.match(url.searchParams.get('fromImage') ?? '',/^(public\.ecr\.aws\/supabase\/|ghcr\.io\/supabase\/|supabase\/|darthsim\/imgproxy$)/);
    return;
  }
  throw new Error('Refused unsupported Docker mutation');
}

export function loopbackCreate(input) {
  const config = structuredClone(input);
  assert.equal(config.Labels?.['com.supabase.cli.project'],project,'Refuse another project');
  assert.notEqual(config.HostConfig?.NetworkMode,'host','Host networking is forbidden');
  assert.equal(Boolean(config.HostConfig?.PublishAllPorts),false,'Implicit published ports are forbidden');
  for (const bindings of Object.values(config.HostConfig?.PortBindings ?? {})) {
    for (const binding of bindings ?? []) {
      assert.match(binding.HostPort,/^5532[0-9]$/,'Unexpected project port');
      binding.HostIp = '127.0.0.1';
    }
  }
  return config;
}

export function verifyContainer(container) {
  assert.equal(container.Config.Labels?.['com.supabase.cli.project'],project,'Refuse another project');
  assert.notEqual(container.HostConfig.NetworkMode,'host','Host networking is forbidden');
  assert.equal(Boolean(container.HostConfig.PublishAllPorts),false);
  for (const bindings of Object.values(container.HostConfig.PortBindings ?? {})) {
    for (const binding of bindings ?? []) {
      assert.equal(binding.HostIp,'127.0.0.1','Requested port is not loopback-only');
      assert.match(binding.HostPort,/^5532[0-9]$/);
    }
  }
  for (const bindings of Object.values(container.NetworkSettings.Ports ?? {})) {
    for (const binding of bindings ?? []) {
      assert.equal(binding.HostIp,'127.0.0.1','Actual port is not loopback-only');
      assert.match(binding.HostPort,/^5532[0-9]$/);
    }
  }
}

export function projectContainers() {
  assert(!process.env.DOCKER_HOST || process.env.DOCKER_HOST.startsWith('unix://'),'Remote Docker hosts are forbidden');
  try {
    const endpoint=execFileSync('docker',['context','inspect','--format','{{.Endpoints.docker.Host}}'],{encoding:'utf8',timeout:10000}).trim();
    assert(endpoint.startsWith('unix://'),'Require a local Docker context');
    const ids = execFileSync('docker',['ps','-aq','--filter',`label=com.supabase.cli.project=${project}`],{encoding:'utf8',timeout:10000}).trim().split(/\s+/).filter(Boolean);
    return ids.length ? JSON.parse(execFileSync('docker',['inspect',...ids],{encoding:'utf8',timeout:10000})) : [];
  } catch { throw new Error('Local Docker inspection failed; response details suppressed'); }
}

export function verifyLocalStack() {
  const containers = projectContainers();
  assert(containers.some(c=>c.Name===`/${database}` && c.State.Running),'Local database must be running');
  for (const container of containers) verifyContainer(container);
  return containers;
}
