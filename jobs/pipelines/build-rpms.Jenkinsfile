import groovy.json.JsonSlurper

@NonCPS
def matchCell(String eventType, String comment, String osVersion, String osArch, String sambaBranch) {
    if (!eventType || eventType == 'push' || eventType == 'pull_request') {
        return true
    }
    if (eventType == 'issue_comment') {
        if (comment =~ /(?m)\/(re)?test\s+all/) {
            return true
        }
        if (comment =~ /(?m)\/(re)?test\s+centos-ci\/build-rpms\s*$/) {
            return true
        }
        def m = comment =~ /(?m)\/(re)?test\s+centos-ci\/build-rpms\/([^\s\/]+)\/([^\s\/]+)\/([^\s\/]+)/
        if (m.find()) {
            return m.group(2) == osVersion &&
                   m.group(3) == sambaBranch &&
                   m.group(4) == osArch
        }
        return false
    }
    return true
}

@NonCPS
def isAuthorizedUser(String author) {
    def admins = ['obnoxxx', 'gd', 'anoopcs9', 'spuiuk', 'nixpanic', 'phlogistonjohn']
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
                "https://api.github.com/repos/samba-in-kubernetes/samba-build/statuses/${COMMIT_SHA}"
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
                script: '''curl -s -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/samba-in-kubernetes/samba-build/pulls/${PULL_REQUEST_ID}"''',
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
def matchCellFilter(String filter, String osVersion, String osArch, String sambaBranch) {
    if (!filter || filter == 'all') {
        return true
    }
    def cell = "${osVersion}/${sambaBranch}/${osArch}"
    for (def item in filter.split(',')) {
        if (item.trim() == cell) {
            return true
        }
    }
    return false
}

def shouldRunCell(String osVersion, String osArch, String sambaBranch) {
    if (!matchCellFilter(params.BUILD_VARIANT_FILTER, osVersion, osArch, sambaBranch)) {
        return false
    }
    if (currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause')) {
        return true
    }
    return matchCell(env.WEBHOOK_EVENT_TYPE, env.WEBHOOK_COMMENT_BODY ?: '', osVersion, osArch, sambaBranch)
}

def buildCell(String osVersion, String osArch, String sambaBranch) {
    def ctx = "centos-ci/build-rpms/${osVersion}/${sambaBranch}/${osArch}"
    def cellName = "samba_build-rpms-${osVersion}-${sambaBranch}-${osArch}"

    node('cico-workspace') {
        checkout([$class: 'GitSCM',
            branches: scm.branches,
            userRemoteConfigs: scm.userRemoteConfigs,
        ])

        withEnv([
            "OS_VERSION=${osVersion}",
            "OS_ARCH=${osArch}",
            "SAMBA_BRANCH=${sambaBranch}",
            "CENTOS_VERSION=9s",
            "DUFFY_POOL_TYPE=virt",
        ]) {
            try {
                if (env.PULL_REQUEST_ID) {
                    notifyGitHub('pending', ctx, 'Build started')
                }

                stage("${cellName} - Provision Node") {
                    sh 'jobs/scripts/common/get-node.sh'
                }

                stage("${cellName} - Copy SSH Key") {
                    sh 'jobs/scripts/common/scp.sh'
                }

                stage("${cellName} - Build") {
                    sh """
                        jobs/scripts/common/bootstrap.sh \
                            \$WORKSPACE/jobs/scripts/nightly-samba-builds/nightly-samba-builds.sh \
                            "BUILD_GIT_REPO=\${BUILD_GIT_REPO} BUILD_GIT_BRANCH=\${BUILD_GIT_BRANCH} PULL_REQUEST_ID=\${PULL_REQUEST_ID} TARGET_BRANCH=\${TARGET_BRANCH} OS_VERSION=\${OS_VERSION} OS_ARCH=\${OS_ARCH} SAMBA_BRANCH=\${SAMBA_BRANCH}"
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
                    to: 'anoopcs@samba.org',
                    replyTo: '$DEFAULT_REPLYTO',
                    subject: "${cellName} - Build # ${env.BUILD_NUMBER} - \${BUILD_STATUS}!",
                    body: '$DEFAULT_CONTENT',
                    mimeType: 'text/plain'
                )
                throw err
            } finally {
                stage("${cellName} - Return Node") {
                    sh 'jobs/scripts/common/return-node.sh'
                }
            }
        }
    }
}

// Trigger configuration
properties([
    buildDiscarder(logRotator(daysToKeepStr: '7', artifactDaysToKeepStr: '7')),
    parameters([
        string(name: 'BUILD_GIT_REPO', defaultValue: 'https://github.com/samba-in-kubernetes/samba-build',
               description: 'Git repo URL of samba-build (for manual triggers)'),
        string(name: 'BUILD_GIT_BRANCH', defaultValue: 'main',
               description: 'Branch of samba-build to build from (for manual triggers)'),
        string(name: 'BUILD_VARIANT_FILTER', defaultValue: 'all',
               description: 'Run a specific build variant (e.g. centos9/master/x86_64) or all')
    ]),
    pipelineTriggers([
        cron('H 0 * * *'),
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
            token: 'samba-build-rpms-trigger',
            tokenCredentialId: '',
            causeString: 'Triggered by GitHub webhook on $WEBHOOK_REPO_FULL_NAME',
            printContributedVariables: true,
            printPostContent: false,
            regexpFilterText: '$WEBHOOK_PR_ACTION $WEBHOOK_COMMENT_BODY $WEBHOOK_PUSH_REF',
            regexpFilterExpression: '^(opened|synchronize|created|edited).*/(re)?test\\s+(all|centos-ci/build-rpms(/[^\\s]*)?).*|^(opened|synchronize).*|^.*refs/heads/main.*$',
        ]
    ])
])

// Matrix definition
def OS_VERSIONS = ['centos9', 'centos10', 'fedora44', 'fedora43']
def OS_ARCHS = ['x86_64', 'aarch64']
def SAMBA_BRANCHES = ['master', 'v4-24-test', 'v4-23-test']

// Main pipeline
node('cico-workspace') {
    stage('Resolve Trigger Context') {
        resolveTriggerContext()
    }
}

def cells = [:]
for (def osVersion in OS_VERSIONS) {
    for (def osArch in OS_ARCHS) {
        for (def sambaBranch in SAMBA_BRANCHES) {
            def ov = osVersion
            def oa = osArch
            def sb = sambaBranch
            if (shouldRunCell(ov, oa, sb)) {
                cells["${ov}-${sb}-${oa}"] = { buildCell(ov, oa, sb) }
            }
        }
    }
}

if (cells.isEmpty()) {
    echo 'No matching cells to build'
} else {
    parallel cells
}
