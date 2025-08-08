pipeline {
  agent any
  stages {
    stage('Checkout') { steps { checkout scm } }
    stage('Smoke')    { steps { sh 'echo OK && git rev-parse --short HEAD' } }
  }
}
