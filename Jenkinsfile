pipeline {
  agent any
  stages {
    stage('Checkout') { steps { checkout scm } }
    stage('Smoke')    { steps { sh 'echo OK && git rev-parse --short HEAD' } }

    stage('Push test (ephemeral branch)') {
      steps {
        withCredentials([string(credentialsId: 'github-pat', variable: 'GITHUB_PAT')]) {
          sh '''
            set -e
            git config user.name "jenkins-bot"
            git config user.email "jenkins-bot@local"
            git remote set-url origin https://${GITHUB_PAT}@github.com/pmcann/Linux-Scripts.git

            BR=ci-ping-$(date +%s)
            git checkout -b "$BR"
            git commit --allow-empty -m "ci: push test ($BR) [skip ci]"
            git push -u origin HEAD:"$BR"

            # Clean up: delete the remote branch, then local
            git push origin :refs/heads/"$BR" || true
            git checkout -
            git branch -D "$BR" || true
          '''
        }
      }
    }
  }
}
