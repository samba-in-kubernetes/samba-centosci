FROM quay.io/centos/centos:stream

RUN true \
 && dnf -y install python3.8 \
 && pip3 install jenkins-job-builder \
 && dnf -y clean all \
 && true

COPY . /opt/build/

# make jobs directory writable, otherwise deploy-jobs.sh fails
RUN chmod ugo=rwx /opt/build/jobs

WORKDIR /opt/build

CMD ["sh", "-c", "deploy/verify-yaml.sh"]
