pipeline {
  agent any

  stages {
    stage('Checkout') { steps { checkout scm } }
    stage('Smoke')    { steps { sh 'echo OK && git rev-parse --short HEAD' } }

    // Build & push a tiny image to ECR using Kaniko
    stage('Kaniko smoke build') {
      steps {
        script {
          podTemplate(
            containers: [
              containerTemplate(
                name: 'kaniko',
                image: 'gcr.io/kaniko-project/executor:latest',
                command: 'sleep', args: '99d', ttyEnabled: true,
                volumeMounts: [ volumeMount(mountPath: '/kaniko/.docker', name: 'docker-config') ]
              )
            ],
            volumes: [ secretVolume(secretName: 'ecr-dockercfg', mountPath: '/kaniko/.docker') ]
          ) {
            node(POD_LABEL) {
              container('kaniko') {
                sh '''
                  set -e
                  ECR="374965728115.dkr.ecr.us-east-1.amazonaws.com"
                  REPO="tripfinder-ci-smoke"
                  TAG="${BUILD_NUMBER}"

                  # Minimal Dockerfile
                  cat > Dockerfile <<'DF'
                  FROM alpine:3.20
                  CMD ["sh","-c","echo hello-from-kaniko"]
                  DF

                  # Build & push
                  /kaniko/executor \
                    --context $PWD \
                    --dockerfile Dockerfile \
                    --destination ${ECR}/${REPO}:${TAG} \
                    --destination ${ECR}/${REPO}:latest
                '''
              }
            }
          }
        }
      }
    }
  }
}
