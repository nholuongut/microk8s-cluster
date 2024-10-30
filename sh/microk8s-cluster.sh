#!/bin/bash

set -e
trap 'catch $? $LINENO' EXIT
catch() {
  if [ "$1" != "0" ]; then
    echo "Error $1 occurred on $2"
  fi
}

REPORT='report.md'

OS=$(uname -a)
echo "$OS" > "$REPORT"
if [[ "$OS" == 'Linux'* ]]
then
   lsb_release -a | tee "$REPORT"
fi

TOTAL_STEPS=2
SCRIPT_COMPLETED='<-<script-completed>->'
STEP_COMPLETED='<-<step-completed>->'
JOIN_CLUSTER_COMMAND_TAG='<-<join-cluster-command-tag>->'


ON_GCE=$(curl -s -i metadata.google.internal | grep 'Google' || true)

echo -e " "
# variables below can be inherited from environment
if [[ -z ${GCP_PROJECT+x} && ! "$ON_GCE" == *'Google'* ]]     ; then echo "ERROR: gcp project not set" && false         ; fi
if [[ -z ${GCP_ZONE+x} ]]                                     ; then GCP_ZONE='us-central1-c'                           ; fi ; echo "gcp zone: $GCP_ZONE"
if [[ -z ${GCE_CREATE+x} ]]                                   ; then GCE_CREATE='true'                                  ; fi ; echo "gce create: $GCE_CREATE"
if [[ -z ${GCE_DELETE+x} ]]                                   ; then GCE_DELETE='false'                                 ; fi ; echo "gce delete: $GCE_DELETE"
if [[ -z ${GCE_IMAGE_FAMILY+x} ]]                             ; then GCE_IMAGE_FAMILY='ubuntu-2004-lts'                 ; fi ; echo "gce image family: $GCE_IMAGE_FAMILY"
if [[ -z ${GCE_IMAGE_PROJECT+x} ]]                            ; then GCE_IMAGE_PROJECT='ubuntu-os-cloud'                ; fi ; echo "gce image project: $GCE_IMAGE_PROJECT"
if [[ -z ${GCE_MACHINE_TYPE+x} ]]                             ; then GCE_MACHINE_TYPE='n1-standard-2'                   ; fi ; echo "gce machine type: $GCE_MACHINE_TYPE"

if [[ -z ${MK8S_VERSION+x} ]]                                 ; then MK8S_VERSION='1.18'                                ; fi ; echo "microk8s version: $MK8S_VERSION"
if [[ -z ${MK8S_TOKEN+x} ]]                                   ; then MK8S_TOKEN='abcdefghijklmnopqrstuvwxyz123456'      ; fi ; echo "microk8s token:  $MK8S_TOKEN"
if [[ -z ${MK8S_NODES+x} ]]                                   ; then MK8S_NODES=3                                       ; fi ; echo "microk8s nodes : $MK8S_NODES"
if [[ -z ${MK8S_NODE_PREFIX+x} ]]                             ; then MK8S_NODE_PREFIX='microk8s-cluster-'               ; fi ; echo "microk8s prefix : $MK8S_NODE_PREFIX"
if [[ -z ${MK8S_PORT_FORWARD+x} ]]                            ; then MK8S_PORT_FORWARD='true'                           ; fi ; echo "microk8s port forward : $MK8S_PORT_FORWARD"

if [[ -z ${MAX_ITERATIONS+x} ]]                               ; then MAX_ITERATIONS=6                                   ; fi ; echo "max iterations : $MAX_ITERATIONS"

echo -e " "

create_gce_instance() 
{
  local GCE_INSTANCE="$1"
  local GCE_IMAGE_FAMILY="$2"
  local GCE_IMAGE_PROJECT="$3"
  local GCE_MACHINE_TYPE="$4"
  GCE_IMAGE=$(gcloud compute images describe-from-family "$GCE_IMAGE_FAMILY"  --project="$GCE_IMAGE_PROJECT" --format="value(name)")
  echo -e "\n### setup instance: $GCE_INSTANCE - image: $GCE_IMAGE - image family: $GCE_IMAGE_FAMILY - image project: $GCE_IMAGE_PROJECT"
  if [[ ! $(gcloud compute instances list --project="$GCP_PROJECT") == *"$GCE_INSTANCE"* ]]
  then 
    gcloud compute instances create \
        --machine-type="$GCE_MACHINE_TYPE"  \
        --image-project="$GCE_IMAGE_PROJECT" \
        --image="$GCE_IMAGE" \
        --zone="$GCP_ZONE" \
        --project="$GCP_PROJECT" \
        "$GCE_INSTANCE"
  fi
  gcloud compute instances list --project="$GCP_PROJECT" | tee "$REPORT"
  while [[ ! $(gcloud compute ssh "$GCE_INSTANCE" --command='uname -a' --zone="$GCP_ZONE" --project="$GCP_PROJECT") == *'Linux'* ]]
  do
    echo -e "instance not ready for ssh..."
    sleep 5 
  done
  gcloud compute ssh "$GCE_INSTANCE" \
      --command='uname -a'  \
      --zone="$GCP_ZONE" \
      --project="$GCP_PROJECT"
}

if [[ $GCE_CREATE == 'true' ]]
then
  
  JOIN_CLUSTER_COMMAND=''
  
  declare -a GCE_INSTANCES=()
  for i in $(seq $MK8S_NODES)
  do
    GCE_INSTANCES+=("$MK8S_NODE_PREFIX$i")
  done
  echo "gce instances: ${GCE_INSTANCES[*]}"
  
  if [[ ! "$ON_GCE" == *'Google'* ]]
  then

    for GCE_INSTANCE in "${GCE_INSTANCES[@]}"
    do
  
      echo -e "### SETUP OF INSTANCE: $GCE_INSTANCE"
        
      echo -e "\n### NOT on GCE\n" 
  
      create_gce_instance "$GCE_INSTANCE" "$GCE_IMAGE_FAMILY" "$GCE_IMAGE_PROJECT" "$GCE_MACHINE_TYPE"
      
      gcloud compute ssh "$GCE_INSTANCE" --command='sudo rm -rf /var/lib/apt/lists/* && (sudo apt update -y || sudo apt update -y) && sudo apt upgrade -y && sudo apt autoremove  -y' --zone="$GCP_ZONE" --project="$GCP_PROJECT"
      gcloud compute scp "$0"  "$GCE_INSTANCE:$(basename $0)" --zone="$GCP_ZONE" --project="$GCP_PROJECT"
      gcloud compute ssh "$GCE_INSTANCE" --command="sudo chmod ugo+x ./$(basename $0)" --zone="$GCP_ZONE" --project="$GCP_PROJECT"
      
      I=0
      STEP=1
      STEP_REPORT_PREFIX="microk8s-cluster-report"
      STEP_REPORT="$STEP_REPORT_PREFIX-$STEP.log" && touch "$STEP_REPORT" && rm "$STEP_REPORT" && touch "$STEP_REPORT"
      while [[ $I -lt $MAX_ITERATIONS && ! $(cat "$STEP_REPORT" | grep "$SCRIPT_COMPLETED") ]]
      do
        I=$((I+1))
        echo -e "\n### triggering script step: $STEP  - iteration: $I - instance: $GCE_INSTANCE"
        gcloud compute ssh "$GCE_INSTANCE" --command="bash ./$(basename $0) $STEP $I $GCE_INSTANCE '$JOIN_CLUSTER_COMMAND'" --zone="$GCP_ZONE" --project="$GCP_PROJECT" | tee -a "$STEP_REPORT"
        if [[ $(cat "$STEP_REPORT" | grep "$STEP_COMPLETED $STEP") ]]
        then
          if [[ "$STEP" -lt "$TOTAL_STEPS" ]]
          then
            STEP=$((STEP+1))
            STEP_REPORT="$STEP_REPORT_PREFIX-$STEP.log" && touch "$STEP_REPORT"
          fi
        fi
        if [[ -n $(cat "$STEP_REPORT" |  grep "$JOIN_CLUSTER_COMMAND_TAG") ]]
        then
           JOIN_CLUSTER_COMMAND=$(cat "$STEP_REPORT" | grep "$JOIN_CLUSTER_COMMAND_TAG" | awk '{$1 = "";  print $0 }')
           echo -e "join cluster command set to: $JOIN_CLUSTER_COMMAND (instance: $GCE_INSTANCE - step: $STEP - iteration: $I)"
        fi
        J=0
        J_MAX=20
        while [[ "$J" -le "$J_MAX" && ! $(gcloud compute ssh "$GCE_INSTANCE" --command='uname -a' --zone="$GCP_ZONE" --project="$GCP_PROJECT") == *'Linux'* ]]
        do
          J=$((J+1))
          if [[ "$J" -gt "$J_MAX" ]]
          then
            echo -e "ERROR: gce instance $GCE_INSTANCE did not come back after reboot"
            exit -1
          fi
          echo -e "instance not ready for ssh..."
          sleep 5s 
        done
        
      done
      
      cat "$STEP_REPORT" | grep "$SCRIPT_COMPLETED"  > /dev/null
      rm "$STEP_REPORT_PREFIX"*
      
    done
    
    #generate report when on Github - get data by scp-ing back to last started instance
    if [[ ! -z "$GITHUB_WORKFLOW" ]]
    then
      echo -e "### generating execution report..."
      gcloud compute scp $GCE_INSTANCE:$REPORT $REPORT --zone $GCP_ZONE --project=$GCP_PROJECT
      cat README.template.md > README.md
    
      echo '## Execution Report' >> README.md
      echo '```' >> README.md
      cat $REPORT >> README.md
      echo '```' >> README.md
    fi
    
    exit 0

  fi 
  
fi

#gcloud compute ssh microk8s-cluster-1 --zone 'us-central1-c' --project=$GCP_PROJECT

echo -e "\n### running on GCE\n"

#GCE_INTERNAL_IP=$(hostname -I | awk '{print $1}')
#GCE_EXTERNAL_IP=$(curl --silent http://ifconfig.me)

[[ -d '.kube' ]] || (mkdir '.kube' && sudo mkdir '/root/.kube')
KUBE_CONFIG="$HOME/.kube/config"
KUBE_ROOT_CONFIG='/root/.kube/config'
sudo rm -f "$KUBE_ROOT_CONFIG"
[[ -f "$KUBE_CONFIG" ]] || (touch "$KUBE_CONFIG" && sudo touch "$KUBE_ROOT_CONFIG")

exec_step1()
{
  local STEP="$1"
  local GCE_INSTANCE="$2"
  
  #set those variables for python-based microk8s enable, add-node, join to work starting with v1.20
  export LC_ALL=C.UTF-8 
  export LANG=C.UTF-8
  
  echo -e "\n### install net-tools: "
  sudo apt update -y && sudo apt install -y net-tools
    
  if [[ -z $(which microk8s) ]]
  then
    echo -e "\n### install microk8s: "
    sudo snap install microk8s --classic --channel="$MK8S_VERSION"
    sudo snap list | grep 'microk8s'
    sudo microk8s status --wait-ready
    sudo usermod -a -G 'microk8s' "$USER"
    sudo chown -f -R "$USER" ~/.kube
  fi
  
  echo -e "$STEP_COMPLETED $STEP on $GCE_INSTANCE"
  
  if [[ -f /var/run/reboot-required ]]
  then
    echo 'WARNING: reboot required. Reboot in 2s...'
    sleep 2s
    sudo reboot
  fi
}

exec_step2()
{
  local STEP="$1"
  local GCE_INSTANCE="$2"
  shift && shift
  JOIN_CLUSTER_COMMAND=("$@")
  
  #set those variables for python-based microk8s enable, add-node, join to work starting with v1.20
  export LC_ALL=C.UTF-8 
  export LANG=C.UTF-8
  
  if [[ -z "$JOIN_CLUSTER_COMMAND" ]]
  then
    echo -e "\n### create cluster: " | tee -a "$REPORT"
    microk8s status --wait-ready
    CREATE_CLUSTER="$(microk8s add-node --token $MK8S_TOKEN --token-ttl 7200)"
    echo -e "$CREATE_CLUSTER" | tee -a "$REPORT"
    JOIN_CLUSTER_COMMAND=$(echo "$CREATE_CLUSTER" | grep -m 1 '^microk8s join')
    echo -e "### join cluster command: $JOIN_CLUSTER_COMMAND" | tee -a "$REPORT"
    #command will be captured from token
    echo -e "$JOIN_CLUSTER_COMMAND_TAG: $JOIN_CLUSTER_COMMAND"
    
    microk8s enable storage | tee -a "$REPORT"
    microk8s enable dns | tee -a "$REPORT"
    microk8s enable dashboard | tee -a "$REPORT"
    microk8s status --wait-ready | tee -a "$REPORT"
  else
    echo -e "\n### join cluster: " | tee -a "$REPORT"
    PRIMARY_IP=$(echo $JOIN_CLUSTER_COMMAND | awk '{print $3}' | sed 's/:.*//' )
    echo -e "### check primary node connectivity from $GCE_INSTANCE: $PRIMARY_IP" | tee -a "$REPORT"
    ping -c 5 "$PRIMARY_IP" | tee -a "$REPORT"
    echo -e "### joining cluster from $GCE_INSTANCE: $JOIN_CLUSTER_COMMAND"
    eval "$JOIN_CLUSTER_COMMAND" | tee -a "$REPORT"
    microk8s status --wait-ready
    
  fi
  
  echo -e "\n### check nodes in cluster: " | tee -a "$REPORT"
  microk8s kubectl get nodes | tee -a "$REPORT"
  
  microk8s status | tee -a "$REPORT"
  
  echo -e "$STEP_COMPLETED $STEP on $GCE_INSTANCE"
  echo -e "$SCRIPT_COMPLETED on $GCE_INSTANCE"
  
  if [[ "$MK8S_PORT_FORWARD" == 'true' ]]
  then
    
    echo -e "\n### port forwarding for dashboards:" 
    
    LOCAL_K8S_DASHBOARD_PORT=3443
    
    K8S_DASHBOARD_PORT=$(microk8s kubectl get -n 'kube-system' 'service/kubernetes-dashboard' --output=jsonpath='{.spec.ports[0].port}')
    echo -e "K8s dashboard ports - gce:  $K8S_DASHBOARD_PORT - local: $LOCAL_K8S_DASHBOARD_PORT " | tee -a "$REPORT"
    (nohup microk8s kubectl port-forward -n 'kube-system' 'service/kubernetes-dashboard' "$LOCAL_K8S_DASHBOARD_PORT:$K8S_DASHBOARD_PORT" | tee -a "$REPORT") >> nohup.out 2>> nohup.err < /dev/null &
    
    echo -e "gcloud command for port-forwarding of K8s & Elastic Search dashboards:  gcloud compute ssh $GCE_INSTANCE --zone=$GCP_ZONE"  \
            ' --project=$GCP_PROJECT ' \
            "--ssh-flag='-L $LOCAL_K8S_DASHBOARD_PORT:localhost:$LOCAL_K8S_DASHBOARD_PORT -L $LOCAL_HUBBLE_DASHBOARD_PORT:localhost:$LOCAL_HUBBLE_DASHBOARD_PORT -L $LOCAL_ES_DASHBOARD_PORT:localhost:$LOCAL_ES_DASHBOARD_PORT -L $LOCAL_KIBANA_DASHBOARD_PORT:localhost:$LOCAL_KIBANA_DASHBOARD_PORT'"  | tee -a "$REPORT" 
    
    echo -e "K8s authentication token: $(microk8s config | grep token | awk '{print $2}')" | tee -a "$REPORT"
    echo -e "K8s dashboard: https://localhost:$LOCAL_K8S_DASHBOARD_PORT" | tee -a "$REPORT"
    
  fi
  
}

exec_main()
{

  local STEP=$1
  local ITERATION=$2
  local GCE_INSTANCE=$3
  shift && shift && shift
  local JOIN_CLUSTER_COMMAND=("$@")
  
  echo -e "executing step: $STEP - iteration: $ITERATION - instance: $GCE_INSTANCE - join cluster command: $JOIN_CLUSTER_COMMAND"
  
  case "$STEP" in
	1)
		exec_step1 "$STEP" "$GCE_INSTANCE"
		;;
	2)
		exec_step2 "$STEP" "$GCE_INSTANCE" "$JOIN_CLUSTER_COMMAND"
		;;
	*)
	  echo -e "Unknown step: $STEP"
		exit 1
		;;
  esac
  
}

STEP=$1
ITERATION=$2
GCE_INSTANCE=$3
shift && shift && shift
JOIN_CLUSTER_COMMAND=("$@")
exec_main "$STEP" "$ITERATION" "$GCE_INSTANCE" "$JOIN_CLUSTER_COMMAND"
