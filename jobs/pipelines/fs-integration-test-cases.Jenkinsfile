import groovy.json.JsonSlurper

def GIT_REPO = 'sit-test-cases'
def GH_REPO_PATH = "samba-in-kubernetes/${GIT_REPO}"
def FILE_SYSTEMS = ['glusterfs', 'xfs', 'cephfs', 'cephfs.mgr', 'gpfs', 'gpfs.scale']

@NonCPS
def matchCell(String eventType, String comment, String fileSystem) {
    if (!eventType || eventType == 'push' || eventType == 'pull_request') {
        return true
    }
    if (eventType == 'issue_comment') {
        if (comment =~ /(?m)\/(re)?test\s+all/) {
            return true
        }
        if (comment =~ /(?m)\/(re)?test\s+centos-ci\s*$/) {
            return true
        }
        def m = comment =~ /(?m)\/(re)?test\s+centos-ci\/([^\s]+)/
        if (m.find()) {
            return m.group(2) == fileSystem
        }
        return false
    }
    return true
}

@NonCPS
def isAuthorizedUser(String author) {
    def admins = ['obnoxxx', 'gd', 'anoopcs9', 'spuiuk', 'phlogistonjohn', 'xhernandez', 'synarete', 'Shwetha-Acharya']
    if (!author) {
        return true
    }
    return admins.contains(author)
}

@NonCPS
def parseJson(String text) {
    return new JsonSlurper().parseText(text)
}

def notifyGitHub(String state, String context, String description) {
    if (!env.COMMIT_SHA) {
        return
    }
    env.GH_STATUS_STATE = state
    env.GH_STATUS_CONTEXT = context
    env.GH_STATUS_DESC = description
    withCredentials([string(credentialsId: 'github-status-token', variable: 'GITHUB_TOKEN')]) {
        sh '''
            json=$(printf '{"state":"%s","context":"%s","description":"%s","target_url":"%s"}' \
                "$GH_STATUS_STATE" "$GH_STATUS_CONTEXT" "$GH_STATUS_DESC" "$BUILD_URL")
            curl -s -X POST \
                -H "Authorization: token ${GITHUB_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$json" \
                "https://api.github.com/repos/samba-in-kubernetes/sit-test-cases/statuses/${COMMIT_SHA}"
        '''
    }
}

def resolveTriggerContext() {
    if (env.WEBHOOK_PR_ACTION in ['opened', 'synchronize']) {
        env.WEBHOOK_EVENT_TYPE = 'pull_request'
        env.PULL_REQUEST_ID    = env.WEBHOOK_PR_NUMBER
        env.TARGET_BRANCH      = env.WEBHOOK_TARGET_BRANCH ?: 'main'
        env.COMMIT_SHA         = env.WEBHOOK_COMMIT_SHA
    } else if (env.WEBHOOK_COMMENT_BODY) {
        env.WEBHOOK_EVENT_TYPE = 'issue_comment'
        env.PULL_REQUEST_ID    = env.WEBHOOK_COMMENT_PR_NUM
        env.TARGET_BRANCH      = 'main'
        withCredentials([string(credentialsId: 'github-status-token', variable: 'GITHUB_TOKEN')]) {
            def prData = sh(
                script: '''curl -s -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/samba-in-kubernetes/sit-test-cases/pulls/${PULL_REQUEST_ID}"''',
                returnStdout: true
            ).trim()
            def prJson = parseJson(prData)
            env.COMMIT_SHA    = prJson.head.sha
            env.TARGET_BRANCH = prJson.base.ref
        }
    } else if (env.WEBHOOK_PUSH_REF == 'refs/heads/main') {
        env.WEBHOOK_EVENT_TYPE = 'push'
        env.PULL_REQUEST_ID    = ''
        env.TARGET_BRANCH      = ''
        env.COMMIT_SHA         = env.WEBHOOK_PUSH_HEAD_SHA
    } else {
        env.WEBHOOK_EVENT_TYPE = ''
        env.PULL_REQUEST_ID    = ''
        env.TARGET_BRANCH      = ''
        env.COMMIT_SHA         = ''
    }

    if (env.WEBHOOK_EVENT_TYPE == 'issue_comment' && !isAuthorizedUser(env.WEBHOOK_COMMENT_AUTHOR ?: '')) {
        currentBuild.result = 'NOT_BUILT'
        error("User ${env.WEBHOOK_COMMENT_AUTHOR} is not authorized to trigger builds")
    }

    if (env.PULL_REQUEST_ID && env.TARGET_BRANCH != 'main') {
        currentBuild.result = 'NOT_BUILT'
        error("PR targets branch '${env.TARGET_BRANCH}', not 'main'. Skipping.")
    }
}

@NonCPS
def filterContains(String filter, String value) {
    for (def item in filter.split(',')) {
        if (item.trim() == value) return true
    }
    return false
}

def shouldRunCell(String fileSystem) {
    def filter = params.FILE_SYSTEM_VARIANT_FILTER
    if (filter && filter != 'all' && !filterContains(filter, fileSystem)) {
        return false
    }
    if (currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause')) {
        return fileSystem != 'glusterfs'
    }
    return matchCell(env.WEBHOOK_EVENT_TYPE, env.WEBHOOK_COMMENT_BODY ?: '', fileSystem)
}

def emailRecipients(String fileSystem) {
    def recipients = 'anoopcs@samba.org,sprabhu@redhat.com'
    if (fileSystem == 'cephfs' || fileSystem == 'cephfs.mgr') {
        recipients += ",${env.CEPH_SMB_RECIPIENTS ?: ''}"
    }
    if (fileSystem == 'gpfs' || fileSystem == 'gpfs.scale') {
        recipients += ",${env.CEPH_SMB_RECIPIENTS ?: ''},${env.SCALE_SMB_RECIPIENTS ?: ''}"
    }
    return recipients
}

def buildCell(String fileSystem) {
    def ctx = "centos-ci/${fileSystem}"
    def cellName = "samba_${fileSystem}-integration-test-cases"

    node('cico-workspace') {
        checkout([$class: 'GitSCM',
            branches: scm.branches,
            userRemoteConfigs: scm.userRemoteConfigs,
        ])

        withEnv([
            "FILE_SYSTEM=${fileSystem}",
            "GIT_REPO=sit-test-cases",
            "CENTOS_VERSION=9s",
            "OS_ARCH=x86_64",
            "DUFFY_POOL_TYPE=metal",
        ]) {
            withCredentials([
                [$class: 'AmazonWebServicesCredentialsBinding',
                 credentialsId: 'aws-s3-credentials',
                 accessKeyVariable: 'S3_ACCESS_KEY',
                 secretKeyVariable: 'S3_SECRET_KEY'],
                string(credentialsId: 'ceph-smb-recipients', variable: 'CEPH_SMB_RECIPIENTS'),
                string(credentialsId: 'scale-smb-recipients', variable: 'SCALE_SMB_RECIPIENTS'),
            ]) {
                try {
                    if (env.PULL_REQUEST_ID) {
                        notifyGitHub('pending', ctx, 'Build started')
                    }

                    stage("${cellName} - Provision Node") {
                        sh 'jobs/scripts/common/get-node.sh'
                    }

                    stage("${cellName} - Build") {
                        sh """
                            jobs/scripts/common/bootstrap.sh \
                                \$WORKSPACE/jobs/scripts/fs-integration/fs-integration.sh \
                                "BUILD_GIT_REPO=\${BUILD_GIT_REPO} PULL_REQUEST_ID=\${PULL_REQUEST_ID} TARGET_BRANCH=\${TARGET_BRANCH} CENTOS_VERSION=\${CENTOS_VERSION} FILE_SYSTEM=\${FILE_SYSTEM} GIT_REPO=\${GIT_REPO} S3_ACCESS_KEY=\${S3_ACCESS_KEY} S3_SECRET_KEY=\${S3_SECRET_KEY}"
                        """
                    }

                    if (env.PULL_REQUEST_ID) {
                        notifyGitHub('success', ctx, 'Build passed')
                    }
                } catch (err) {
                    currentBuild.result = 'FAILURE'
                    if (env.PULL_REQUEST_ID) {
                        notifyGitHub('failure', ctx, 'Build failed')
                    }
                    emailext(
                        to: emailRecipients(fileSystem),
                        replyTo: '$DEFAULT_REPLYTO',
                        subject: "${cellName} - Build # ${env.BUILD_NUMBER} - \${BUILD_STATUS}!",
                        body: '$DEFAULT_CONTENT',
                        mimeType: 'text/plain',
                        attachLog: true
                    )
                    throw err
                } finally {
                    stage("${cellName} - Copy Results") {
                        sh "jobs/scripts/fs-integration/copy.sh || true"
                        sh "mkdir -p ${fileSystem} && mv -f test.out *.tar.gz ${fileSystem}/ 2>/dev/null || true"
                        archiveArtifacts artifacts: "${fileSystem}/**", allowEmptyArchive: true
                    }
                    stage("${cellName} - Return Node") {
                        sh 'jobs/scripts/common/return-node.sh'
                    }
                }
            }
        }
    }
}

properties([
    buildDiscarder(logRotator(daysToKeepStr: '7', artifactDaysToKeepStr: '7')),
    parameters([
        string(name: 'BUILD_GIT_REPO', defaultValue: 'https://github.com/samba-in-kubernetes/sit-test-cases',
               description: 'Git repo URL of sit-test-cases (for manual triggers)'),
        string(name: 'BUILD_GIT_BRANCH', defaultValue: 'main',
               description: 'Branch of sit-test-cases to build from (for manual triggers)'),
        string(name: 'FILE_SYSTEM_VARIANT_FILTER', defaultValue: 'all',
               description: 'Run a specific file system variant (e.g. cephfs) or all')
    ]),
    pipelineTriggers([
        cron('H 2 * * *'),
        [$class: 'GenericTrigger',
            genericVariables: [
                [key: 'WEBHOOK_PR_NUMBER',      value: '$.pull_request.number',   defaultValue: ''],
                [key: 'WEBHOOK_TARGET_BRANCH',  value: '$.pull_request.base.ref', defaultValue: ''],
                [key: 'WEBHOOK_COMMIT_SHA',     value: '$.pull_request.head.sha', defaultValue: ''],
                [key: 'WEBHOOK_PR_ACTION',      value: '$.action',                defaultValue: ''],
                [key: 'WEBHOOK_COMMENT_BODY',   value: '$.comment.body',          defaultValue: ''],
                [key: 'WEBHOOK_COMMENT_AUTHOR', value: '$.comment.user.login',    defaultValue: ''],
                [key: 'WEBHOOK_COMMENT_PR_NUM', value: '$.issue.number',          defaultValue: ''],
                [key: 'WEBHOOK_PUSH_REF',       value: '$.ref',                   defaultValue: ''],
                [key: 'WEBHOOK_PUSH_HEAD_SHA',  value: '$.after',                 defaultValue: ''],
                [key: 'WEBHOOK_REPO_FULL_NAME', value: '$.repository.full_name',  defaultValue: ''],
            ],
            token: 'samba-fs-integration-test-cases-trigger',
            tokenCredentialId: '',
            causeString: 'Triggered by GitHub webhook on $WEBHOOK_REPO_FULL_NAME',
            printContributedVariables: true,
            printPostContent: false,
            regexpFilterText: '$WEBHOOK_PR_ACTION $WEBHOOK_COMMENT_BODY $WEBHOOK_PUSH_REF',
            regexpFilterExpression: '^(opened|synchronize|created|edited).*/(re)?test\\s+(all|centos-ci(/[^\\s]*)?).*|^(opened|synchronize).*|^.*refs/heads/main.*$',
        ]
    ])
])

node('cico-workspace') {
    stage('Resolve Trigger Context') {
        resolveTriggerContext()
    }
}

def cells = [:]
for (def fs in FILE_SYSTEMS) {
    def fileSystem = fs
    if (shouldRunCell(fileSystem)) {
        cells["${fileSystem}"] = { buildCell(fileSystem) }
    }
}

if (cells.isEmpty()) {
    echo 'No matching cells to build'
} else {
    parallel cells
}
