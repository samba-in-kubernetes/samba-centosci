# CentOS CI

This repository contains Jenkins Job Builder files and Openshift object specs for testing Samba and related integration projects. These jobs are run on OCP4 based [Jenkins][ocp4-jenkins] instance using [Jenkins Job Builder][jjb].

[ocp4-jenkins]: https://jenkins-samba.apps.ocp.ci.centos.org/
[jjb]: https://jenkins-job-builder.readthedocs.io/en/latest/

## Respository breakdown

- [.github/workflows/](https://github.com/anoopcs9/samba-centosci/tree/main/.github/workflows)
	- *deploy.yaml*: GitHub action file to update various job descriptions to Jenkins as and when they are changed in the repository.
	- *verify.yaml*: GitHub action file to verify YAML changes for each and every pull request raised in the repository.
- [deploy/](https://github.com/anoopcs9/samba-centosci/tree/main/deploy)
	- *container-registry.yaml*: Openshift spec for project/namespaced deployment of a local image registry within CentOS CI.
	- *deploy-jobs.sh*: Helper script to update jobs in Jenkins using jenkins-jobs commandline utility. Used as alternate entrypoint for container built with Dockerfile.
	- *Dockerfile*: Instructions to build a container with jenkins-jobs installed to handle job configuration changes.
	- *jenkins.conf*: Configurations to connect to Jenkins instance running on Openhift.
	- *verify-yaml.sh*: Helper script to perform check on YAML changes. Default entrypoint inside container

- [jobs/](https://github.com/anoopcs9/samba-centosci/tree/main/jobs)

	Actual definitions for various jobs under [Jenkins][ocp4-jenkins]

- [mirror/](https://github.com/anoopcs9/samba-centosci/tree/main/mirror)

	Openshift specs of a CronJob mirroring those images from docker.io which may get blocked while pulling due to "Download rate limit exceeded" error.
- [prune/](https://github.com/anoopcs9/samba-centosci/tree/main/prune)

	Openshift specs of a CronJob to clean up images marked for deletion within local CI registry using docker registry's garbage collection.
