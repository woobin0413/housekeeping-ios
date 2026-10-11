import test from 'node:test';
import assert from 'node:assert/strict';
import { authorizeDockerMutation, loopbackCreate, verifyContainer, project } from './local-safety.mjs';

const config = () => ({Labels:{'com.supabase.cli.project':project},HostConfig:{PortBindings:{'5432/tcp':[{HostIp:'',HostPort:'55322'}]}}});
test('rewrite happens before creation without mutating caller input',()=>{
  const input=config();
  assert.equal(loopbackCreate(input).HostConfig.PortBindings['5432/tcp'][0].HostIp,'127.0.0.1');
  assert.equal(input.HostConfig.PortBindings['5432/tcp'][0].HostIp,'');
});
test('refuse other project, host network, unexpected port and publish-all',()=>{
  const cases=[config(),config(),config(),config()];
  cases[0].Labels['com.supabase.cli.project']='other';
  cases[1].HostConfig.NetworkMode='host';
  cases[2].HostConfig.PortBindings['5432/tcp'][0].HostPort='54322';
  cases[3].HostConfig.PublishAllPorts=true;
  for(const value of cases) assert.throws(()=>loopbackCreate(value));
});
test('inspection checks both requested and actual published ports',()=>{
  const safe=loopbackCreate(config());
  const container={Config:safe,HostConfig:safe.HostConfig,NetworkSettings:{Ports:structuredClone(safe.HostConfig.PortBindings)}};
  assert.doesNotThrow(()=>verifyContainer(container));
  container.NetworkSettings.Ports['5432/tcp'][0].HostIp='0.0.0.0';
  assert.throws(()=>verifyContainer(container));
  container.NetworkSettings.Ports['5432/tcp'][0].HostIp='::';
  assert.throws(()=>verifyContainer(container));
});
test('mutation guard denies global operations and unrelated resources',async()=>{
  const inspect=async path=>({Config:{Labels:{'com.supabase.cli.project':path.includes('ours') ? project : 'other'}}});
  await assert.doesNotReject(()=>authorizeDockerMutation('POST','/v1.51/containers/ours/start',undefined,inspect));
  for(const [method,path] of [['POST','/containers/theirs/stop'],['DELETE','/containers/theirs'],
    ['POST','/containers/prune'],['POST','/volumes/prune'],['POST','/networks/prune'],['POST','/images/prune']]) {
    await assert.rejects(()=>authorizeDockerMutation(method,path,undefined,inspect));
  }
});
test('exec mutation verifies its owning container',async()=>{
  const inspect=async path=>path.startsWith('/exec/') ? {ContainerID:'other'} : {Config:{Labels:{'com.supabase.cli.project':'other'}}};
  await assert.rejects(()=>authorizeDockerMutation('POST','/exec/123/start',undefined,inspect));
});
