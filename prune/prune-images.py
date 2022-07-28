from time import time, sleep
from kubernetes import client, config
from kubernetes.stream import stream

namespace = "samba"
reg_deployment = "container-registry"

# Load configuration within cluster
config.load_incluster_config()

Appsv1 = client.AppsV1Api()
deployment = Appsv1.read_namespaced_deployment(reg_deployment, namespace)

"""
Check whether registry is in Read Only mode

It is recommended to put registry in Read Only mode during garbage collection
process
"""
def Is_ReadOnly():
    for container in deployment.spec.template.spec.containers:
        if container.env is None:
            return False
        for env in container.env:
            if env.name == "REGISTRY_STORAGE_MAINTENANCE_READONLY":
                return True if (env.value == "enabled: true") else False
    return False

"""
Set/Unset registry Read Only mode

We use REGISTRY_STORAGE_MAINTENANCE_READONLY and not
REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED because of difference in
interpretation for 'storage.maintenance' configuration options. See GitHub
issue https://github.com/distribution/distribution/issues/2974 for more
details
"""
def ReadOnly(status: str):
    for env in deployment.spec.template.spec.containers[0].env:
        if env.name == "REGISTRY_STORAGE_MAINTENANCE_READONLY":
            env.value = "enabled: " + status
            break
    else:
        deployment.spec.template.spec.containers[0].env.append(client.V1EnvVar("REGISTRY_STORAGE_MAINTENANCE_READONLY", "enabled: " + status))

"""
Wait for deployment rollout to be complete after updation

Wait for any delay in rollout process which should happen automatically after
patching is done.
"""
def Wait_for_Rollout(timeout=600):
    print("Waiting for Rollout completeness..")

    start = time()
    while time() - start < timeout:
        resp = Appsv1.read_namespaced_deployment_status(reg_deployment, namespace)
        s = resp.status
        if (s.updated_replicas == resp.spec.replicas and
                s.replicas == resp.spec.replicas and
                s.available_replicas == resp.spec.replicas and
                s.observed_generation >= resp.metadata.generation):
            print("Rollout completed successfully")
            return
        else:
            sleep(2)

    raise Exception("Waiting for Rollout timed out (10m) !")


def main():
    # Make sure that registry is Read Only before running garbage collection
    if not Is_ReadOnly():
        ReadOnly("true")
        Appsv1.patch_namespaced_deployment(reg_deployment, namespace, deployment)
        Wait_for_Rollout()

    # Filter out the pod hosting registry and run garbage collection tool
    v1 = client.CoreV1Api()
    pods = v1.list_namespaced_pod(namespace,
                                  label_selector='name=container-registry')

    reg_pod = pods.items[0].metadata.name

    exec_command = ['/bin/sh', '-c',
                    '/bin/registry garbage-collect --delete-untagged /etc/docker/registry/config.yml']
    rsp = stream(v1.connect_get_namespaced_pod_exec,
                 reg_pod, namespace, command=exec_command,
                 stderr=True, stdin=False, stdout=True, tty=False)

    print("Garbage collection run results: \n" + rsp)

    # Disable Read Only mode after cleaning process is completed
    if Is_ReadOnly():
        ReadOnly("false")
        Appsv1.patch_namespaced_deployment(reg_deployment, namespace, deployment)
        Wait_for_Rollout()

    return

if __name__ == '__main__':
    main()
