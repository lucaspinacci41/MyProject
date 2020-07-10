#!/usr/bin/env bash

if [[ -z ${LOG_FILE_NAME+x} ]]; then
    LOG_FILE_NAME="setup_$(date "+%y_%m_%d_%H_%M_%S").log"
    . ./setup.sh 2>&1 | tee -a "${LOG_FILE_NAME}"
    exit $?
fi

# Prompt colors
Color_Off='\e[0m'       # Text Reset
Red='\e[0;31m'          # Rosso
Yellow='\e[0;33m'       # Giallo
Blue='\e[0;34m'         # Blu
Cyan='\e[0;36m'         # Ciano

RES_PREREQUISITES_SUCCESS=false
RES_DOCKER_INSTALL_SUCCESS=false
RES_DOCKER_COMPOSE_INSTALL_SUCCESS=false
RES_DOCKERHUB_LOGIN_SUCCESS=false
RES_LICENSE_MANAGER_INSTALL_SUCCESS=false
RES_CSC_IMAGES_INSTALL_SUCCESS=false
RES_MCS_IMAGE_INSTALL_SUCCESS=false
RES_TEST_CONFIG_INSTALL_SUCCESS=false
RES_DB_SETUP_SUCCESS=false

EXECUTION_MODE="install"
COMPONENT_TYPE_INSTALL="ALL"
LMA_SERVER_USER="lma"
MCS_SERVER_USER="mcs"
DOCKER_HUB_USERNAME=""
DOCKER_HUB_PASSWORD=""

EXEC_INSTALL_PRE="1"
EXEC_INSTALL_LM="1"
EXEC_UNINSTALL_LM="0"
EXEC_INSTALL_DOCKER="1"
EXEC_INSTALL_DOCKER_COMPOSE="1"
EXEC_COPY_SCRIPTS="1"
EXEC_SETUP_DB="1"
EXEC_SETUP_FIREWALL="1"
EXEC_SETUP_TEST_CONFIGURATION="1"

CURRENT_USER=$(whoami)
CURRENT_DIR=$(pwd)
if [ "${CURRENT_USER}" != "root" ]; then
    echo "This script must be run under \"root\" user."
    exit 1
fi

SELINUX_STATUS=$(sestatus)
if [[ $? -eq 0 ]]; then
    if [ "${SELINUX_STATUS}" != "SELinux status:                 disabled" ]; then
        echo "SELINUX STILL ENABLED. Disable it before proceeding with setup"
        exit 1
    fi
fi

CENTOS_VERSION=$(cat /etc/centos-release)
CENTOS_VERSION=${CENTOS_VERSION:21:1}

if [[ "${CENTOS_VERSION}" != "7" ]] && [[ "${CENTOS_VERSION}" != "8" ]]; then
    echo "UNSUPPORTED OPERATING SYSTEM. MCXPTT can only be installed on CentOS/RHEL 7 or 8"
    exit 1
fi

function usage
{
    echo ""
    echo "Usage: $0 [-h|--help] " 1>&2 
    echo ""

    echo "Options:
    --csc                   Install only CSC components
    --mcs                   Install only MCS components
    --no-license-manager    Do not extract and install the license manager application
    --no-test-configuration Avoid installing provided test configuration. Valid only on first install execution
    --test-configuration    Install test configuration. Valid on update or reinstall
    --update                Do an update of only the docker images. Doesn't reinstall the test configuration
    --reinstall             Install and overwrite every installed component, images and configuration. Your installed license will be lost. Doesn't reinstall the test configuration or touch your database
    -h|--help               Show this help"
    echo ""
}

POSITIONAL=()
while [[ $# -gt 0 ]]
do
    key="$1"

    case $key in
        -h|--help)
            usage
            exit
        ;;
        --csc)
			COMPONENT_TYPE_INSTALL="CSC"
            shift # pass argument
        ;;
        --mcs)
			COMPONENT_TYPE_INSTALL="MCS"
            shift # pass argument
        ;;
        --no-license-manager)
			EXEC_INSTALL_LM="0"
            shift # pass argument
        ;;
        --no-test-configuration)
            EXEC_SETUP_TEST_CONFIGURATION="0"
            shift
        ;;
        -u|--username)
            DOCKER_HUB_USERNAME=${2}
            shift
            shift
        ;;
        -p|--password)
            DOCKER_HUB_PASSWORD=${2}
            shift
            shift
        ;;
        --update)
            if [[ ${EXECUTION_MODE} != "reinstall" ]]; then
                EXECUTION_MODE="update"
                EXEC_INSTALL_PRE="0"
                EXEC_INSTALL_LM="0"
                EXEC_UNINSTALL_LM="0"
                EXEC_INSTALL_DOCKER="0"
                EXEC_INSTALL_DOCKER_COMPOSE="0"
                EXEC_COPY_SCRIPTS="0"
                EXEC_SETUP_DB="0"
                EXEC_SETUP_FIREWALL="0"
                EXEC_SETUP_TEST_CONFIGURATION="0"
            fi
            shift
        ;;
        --reinstall)
            EXECUTION_MODE="reinstall"
            EXEC_UNINSTALL_LM="1"
            EXEC_SETUP_TEST_CONFIGURATION="0"
            shift
        ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
        ;;
    esac
done
set -- "${POSITIONAL[@]}"

function install_recap
{
    local FORCE_RES_PRE=""
    local FORCE_RES_LMIS=""
    local FORCE_RES_DOCK=""
    local FORCE_RES_DOCKC=""
    local FORCE_RES_MCSIS=""
    local FORCE_RES_CSCIS=""
    local FORCE_RES_DB=""
    local FORCE_RES_TCIS=""
    
    if [[ "${EXEC_INSTALL_PRE}" != "1" ]]; then
        FORCE_RES_PRE="NO"
    fi
    if [[ "${EXEC_INSTALL_LM}" != "1" ]]; then
        FORCE_RES_LMIS="NO"
    fi
    if [[ "${EXEC_INSTALL_DOCKER}" != "1" ]]; then
        FORCE_RES_DOCK="NO"
    fi
    if [[ "${EXEC_INSTALL_DOCKER_COMPOSE}" != "1" ]]; then
        FORCE_RES_DOCKC="NO"
    fi
    if [[ "${COMPONENT_TYPE_INSTALL}" == "MCS" ]]; then
        FORCE_RES_CSCIS="NO"
    fi
    if [[ "${COMPONENT_TYPE_INSTALL}" == "CSC" ]]; then
        FORCE_RES_MCSIS="NO"
    fi
    if [[ "${EXEC_SETUP_DB}" != "1" ]]; then
        FORCE_RES_DB="NO"
    fi
    if [[ "${EXEC_SETUP_TEST_CONFIGURATION}" != "1" ]]; then
        FORCE_RES_TCIS="NO"
    fi

    echo ""
    echo "----------------------------------------------------------------"
    install_recap_item "Prerequisites" ${RES_PREREQUISITES_SUCCESS} ${FORCE_RES_PRE}
    install_recap_item "License manager" ${RES_LICENSE_MANAGER_INSTALL_SUCCESS} ${FORCE_RES_LMIS}
    install_recap_item "Docker" ${RES_DOCKER_INSTALL_SUCCESS} ${FORCE_RES_DOCK}
    install_recap_item "Docker compose" ${RES_DOCKER_COMPOSE_INSTALL_SUCCESS} ${FORCE_RES_DOCKC}
    install_recap_item "Dockerhub login" ${RES_DOCKERHUB_LOGIN_SUCCESS}
    install_recap_item "MCS image" ${RES_MCS_IMAGE_INSTALL_SUCCESS} ${FORCE_RES_MCSIS}
    install_recap_item "CSC images" ${RES_CSC_IMAGES_INSTALL_SUCCESS} ${FORCE_RES_CSCIS}
    install_recap_item "Database" ${RES_DB_SETUP_SUCCESS} ${FORCE_RES_DB}
    install_recap_item "Test configuration" ${RES_TEST_CONFIG_INSTALL_SUCCESS} ${FORCE_RES_TCIS}
    echo "----------------------------------------------------------------"    
    echo ""
}

function install_recap_item
{
    local RES_COLOR=${Color_Off}
    local RES_VALUE="OK"

    if [[ "${2}" == "false" ]]; then
        RES_COLOR=${Red}
        RES_VALUE="KO"
    fi
    if [[ "${3}" != "" ]]; then
        RES_COLOR=${Yellow}
        RES_VALUE=${3}
    fi

    local TEXT="${1}"
    local SPACES="                                                                " 
    TEXT="${TEXT:0:58}${SPACES:0:$((58 - ${#TEXT}))}"
    echo -e " - ${RES_COLOR}${TEXT} ${RES_VALUE}${Color_Off}"
}

trap ctrl_c INT

function ctrl_c() 
{
    echo ""
    echo ""

    docker logout

    install_recap

    echo ""
    echo -e "${Red}--------------------------------------"
    echo -e " Execution aborted, exit installation"
    echo -e "--------------------------------------${Color_Off}"
    echo ""
    exit 1
}

function shutdown
{
    echo ""
    echo ""

    docker logout

    install_recap

    echo ""
    echo -e "${Red}--------------------------------------"
    echo -e " Installation failed"
    if [[ ${1} != "" ]]; then
        echo -e "${1}"
    fi
    echo -e "--------------------------------------${Color_Off}"
    echo ""
    exit 1
}

function confirm
{
    local QUESTION="${1}"
    read -p "> ${QUESTION} (y/n)?" choice
    case "$choice" in 
        y|Y ) echo "yes";;
        yes|YES ) echo "yes";;
        * ) echo "no";;
    esac
}

function log
{
    local MESSAGE="${1}"
    echo " > ${MESSAGE}"
}

function alert
{
    local MESSAGE="${1}"
    echo -e " > ${MESSAGE}"
}

function danger
{
    local MESSAGE="${1}"
    echo -e " ! ${Red} ${MESSAGE} ${Color_Off}"
    echo ""
}

function warning
{
    local MESSAGE="${1}"
    echo -e " ! ${Yellow} ${MESSAGE} ${Color_Off}"
    echo ""
}

function header
{
    local MESSAGE="${1}"
    echo -e "${Cyan}│"
    echo -e "│ ${MESSAGE}"
    echo -e "└────────────────────────────────────────────────${Color_Off}"
    echo ""
}

function install_base
{
    log "installing base rpm"

    SEARCHED=$(uname -a | grep "GNU/Linux")

    if [ "${SEARCHED}" == "" ]; then
        log "Not a linux system. Quitting"
        exit 1
    fi
    
    if [ -n "$(command -v yum)" ]; then
        yum update -y -q
        yum install -y -q epel-release deltarpm
        yum install -y -q wget nano rsync psmisc
    else
        log "Not a RHEL/CentOS system. Quitting"
        exit 1
    fi

    RES_PREREQUISITES_SUCCESS=true
}

function check_is_docker_installed
{
    if [[ ! -e "/usr/bin/docker" ]]; then
        echo "0"
        return 1
    fi

    DOCKER_VERSION=$(docker -v)
    if [[ ! ${?} -eq 0 ]]; then
        echo "0"
        return 1
    fi

    echo "1"
    return 0
}

function install_docker
{
    header "Installing docker..."

    if [ "${CENTOS_VERSION}" == "7" ]; then
        yum install -y -q yum-utils device-mapper-persistent-data lvm2
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

        yum install -y -q docker-ce docker-ce-cli containerd.io
    elif [ "${CENTOS_VERSION}" == "8" ]; then
        dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
        dnf install docker-ce --nobest -y -q
    else
        echo "This OS is not supported!"
        exit    
    fi
    
    if [[ ! -e "/usr/bin/docker" ]]; then
        danger "Docker command not installed, cannot be found"
        return 1
    fi

    systemctl enable docker
    systemctl start docker
    
    docker -v
    if [[ ${?} != "0" ]]; then
        warning "Failed execution of docker command"
        return 1
    fi
    echo ""
    echo " > Docker installed"
    echo ""

    RES_DOCKER_INSTALL_SUCCESS=true

    return 0
}

function install_docker_compose
{
    header "Installing docker-compose..."

    curl -L "https://github.com/docker/compose/releases/download/1.25.4/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

    if [[ ! -e "/usr/local/bin/docker-compose" ]]; then
        error "Docker-compose command not installed, cannot be found"
        return 1
    fi

    chmod +x /usr/local/bin/docker-compose

    docker-compose -v
    if [[ ${?} != "0" ]]; then
        warning "Failed execution of docker-compose command"
        return 1
    fi

    echo ""
    echo " > Docker-compose installed"
    echo ""

    RES_DOCKER_COMPOSE_INSTALL_SUCCESS=true
    return 0
}

function enable_docker_tcp
{
    header "Enabling docker socket tcp on port 2375 (http)..."

    mkdir -p /etc/systemd/system/docker.service.d/
    echo "# /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375" >> /etc/systemd/system/docker.service.d/override.conf

    systemctl daemon-reload
    systemctl restart docker.service
}

function docker_login
{
    header "Login in docker if not already logged in"

    local RESULT=false
    while [[ "${RESULT}" == "false" ]]
    do
        if [[ "${DOCKER_HUB_USERNAME}" != "" && "${DOCKER_HUB_PASSWORD}" != "" ]]; then
            echo "${DOCKER_HUB_PASSWORD}" | docker login --username "${DOCKER_HUB_USERNAME}" --password-stdin
        elif [[ "${DOCKER_HUB_USERNAME}" != "" ]]; then
            docker login --username "${DOCKER_HUB_USERNAME}"
        else
            docker login
        fi

        if [[ "$?" == "0" ]]; then
            RES_DOCKERHUB_LOGIN_SUCCESS=true
            RESULT=true
        else
            echo ""
        fi
    done

    return 0
}

function extract_tgz
{
	local FILE_NAME=${1}
    local EXTRACT_PATH=${2}
	
    echo "Extracting file: ${FILE_NAME}"
	
    mkdir -p "${EXTRACT_PATH}"
	tar -C "${EXTRACT_PATH}" -zxf ${FILE_NAME}
}

function find_license_manager_tgz_and_extract
{
    local EXTRACT_TO_PATH=${1}
	rm -rf ${EXTRACT_TO_PATH}*

	for FILE_NAME in ./*
	do
		if [ "${FILE_NAME:(-4)}" == ".tgz" ]; then

			echo "Checking file: ${FILE_NAME}"

        	if [[ ${FILE_NAME} == "./mcpttlicensemanager_"* ]]; then
				extract_tgz "${FILE_NAME}" "${EXTRACT_TO_PATH}"
				# only one mcs service is installed
				break
			fi
		fi
	done
}

function install_test_configuration
{
    cd ./scripts;
    local FILES=( ./*.json )
    if [[ ${#FILES[@]} > 0 ]]; then
        local JSON=$(cat ${FILES[0]})
        local DATA="{\"json\": ${JSON}}"
        local RESULT=$(curl -d $"${DATA}" -H "Content-Type: application/json" -X POST "http://127.0.0.1:22001/api/management/teams/import")
        if [[ ${RESULT} != "" ]]; then
            local TEAM_ID=$(echo "${RESULT}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["teamId"]')
            local RESULT=$(curl -X POST "http://127.0.0.1:22001/api/management/teams/set_default?team_id=${TEAM_ID}")

            alert "Imported team ${TEAM_ID}"

            return 0
        else
            alert "Cannot import team"
        fi
    else
        alert "No team to import"
    fi

    return 1
}

function create_user
{
    local USER=${1}
    if [[ ! -d "/home/${USER}" ]]; then
        adduser ${USER}
        su - ${USER} -c "mkdir -p mcptt.talkway.it; "
    fi
}

function uninstall_license_manager
{
    log "License manager already exists, reinstalling"

    su - ${LMA_SERVER_USER} -c "cd mcptt.talkway.it/licensemanager; \
mcpttlicensemanager stop; "

    killall mcpttlicensemanager
    mcpttlicensemanager uninstalldaemon "${LMA_SERVER_USER}"
    mcpttlicensemanager uninstall

    rm -rf /home/${LMA_SERVER_USER}/mcptt.talkway.it/licensemanager/mcpttlicensemanager
}

function install_license_manager
{
    yum install -y -q minizip expat

    create_user ${LMA_SERVER_USER}
    su - ${LMA_SERVER_USER} -c "mkdir -p mcptt.talkway.it/licensemanager;" 

    if [[ -e "/home/${LMA_SERVER_USER}/mcptt.talkway.it/licensemanager/mcpttlicensemanager" ]]; then
        if [[ "${EXEC_UNINSTALL_LM}" == "1" ]]; then
            uninstall_license_manager
        else
            RES_LICENSE_MANAGER_INSTALL_SUCCESS=true
            return 0
        fi
    fi

    cd licensemanager
    find_license_manager_tgz_and_extract "/home/${LMA_SERVER_USER}/mcptt.talkway.it/licensemanager/"

    if [[ -e "/home/${LMA_SERVER_USER}/mcptt.talkway.it/licensemanager/mcpttlicensemanager" ]]; then
        chown ${LMA_SERVER_USER}:${LMA_SERVER_USER} "/home/${LMA_SERVER_USER}/mcptt.talkway.it/licensemanager/mcpttlicensemanager"

        su - ${LMA_SERVER_USER} -c "cd mcptt.talkway.it/licensemanager; \
chmod +x mcpttlicensemanager; "

        cd /home/${LMA_SERVER_USER}/mcptt.talkway.it/licensemanager/
        
        ./mcpttlicensemanager install
        mcpttlicensemanager installdaemon "${LMA_SERVER_USER}"

        su - ${LMA_SERVER_USER} -c "cd mcptt.talkway.it/licensemanager; \
mcpttlicensemanager start; "

        sleep 2

        LMA_CURL_RESPONSE_CODE=$(curl --write-out %{http_code} --silent --output /dev/null http://localhost:14490/license/check)
        if [[ "${LMA_CURL_RESPONSE_CODE}" == "401" ]]; then
            RES_LICENSE_MANAGER_INSTALL_SUCCESS=true
        else
            warning "License manager installed but not responding"
        fi
    else
        danger "License manager cannot be installed"
    fi
}

function setup_database
{
    # create mcptt DB in postgreSQL DBMS
    docker-compose exec postgres psql -U postgres -c 'CREATE DATABASE mcptt' postgres
    if [[ ! $? -eq 0 ]]; then
        danger "Database creation failed on PostgreSQL"
        if [[ "${EXECUTION_MODE}" == "install" ]]; then
            return 1
        fi
    fi
    # create default users superuser and admin for csc configurator
    docker-compose exec mongo mongo --eval 'db.getCollection("users").insertMany([{"user_id": 1, "identity": "superuser", "password": "superpass", "role": 100}, {"user_id": 2, "identity": "admin", "password": "pass", "role": 90}]);' mcptt
    if [[ ! $? -eq 0 ]]; then
        danger "Database creation failed on MongoDB"
        if [[ "${EXECUTION_MODE}" == "install" ]]; then
            return 1
        fi
    fi

    RES_DB_SETUP_SUCCESS=true
    return 0
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# MAIN
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

header "MCXPTT setup script"

# region preparation
IS_DOCKER_INSTALLED=$(check_is_docker_installed)
if [[ ! ${?} -eq 0 ]]; then
    IS_DOCKER_INSTALLED="0"
fi

if [[ "${IS_DOCKER_INSTALLED}" == "1" ]]; then
    if [[ "${EXECUTION_MODE}" == "install" ]]; then
        shutdown " Docker already installed, cannot do a clean install.
 Use --update if you want to update the docker images
 Or --reinstall to try to overwrite and reinstall all images and configurations"
    fi
fi

if [[ "${EXECUTION_MODE}" != "install" ]]; then
    EXEC_CREATE_USER="0"
fi
# endregion preparation

if [[ "${EXEC_INSTALL_PRE}" == "1" ]]; then
    create_user ${MCS_SERVER_USER}

    install_base
fi

if [[ "${EXEC_INSTALL_LM}" == "1" ]]; then
    header "Installing license manager"

    install_license_manager

    cd "${CURRENT_DIR}"
fi

if [ "${COMPONENT_TYPE_INSTALL}" != "CSC" ]; then
    header "Installing MCS"

    cd /home/${MCS_SERVER_USER}/mcptt.talkway.it/

    if [[ "${EXEC_INSTALL_DOCKER}" == "1" ]]; then
        install_docker
        if [[ ! ${?} == "0" ]]; then
            shutdown
        fi
        
        #configure_docker_logs_fluentd

        enable_docker_tcp
    fi

    docker_login

    docker pull aleasrl/mcxptt_mcs:1.2.2_RC
    if [[ $? -eq 0 ]]; then
        RES_MCS_IMAGE_INSTALL_SUCCESS=true

        docker image prune -f
    else
        warning "MCS Image cannot be installed"
        shutdown
    fi

    cd "${CURRENT_DIR}"
fi

if [ "${COMPONENT_TYPE_INSTALL}" != "MCS" ]; then
    header "Installing CSC"
    
    mkdir -p /volumes/mongo
    mkdir -p /volumes/postgres
    
    if [[ "${EXECUTION_MODE}" != "install" ]]; then
        cd /home/${MCS_SERVER_USER}/mcptt.talkway.it/

        if [[ -e "./docker-compose.yml" ]]; then
            echo "Turning down current csc docker images"
            docker-compose down
        else
            warning "docker-compose.yml file not found"
        fi

        cd "${CURRENT_DIR}"
    fi

    if [[ "${EXEC_COPY_SCRIPTS}" == "1" ]]; then
        cp -R ./scripts/* /home/${MCS_SERVER_USER}/mcptt.talkway.it/
        cd /home/${MCS_SERVER_USER}/mcptt.talkway.it/
        chown -R ${MCS_SERVER_USER}:${MCS_SERVER_USER} *
    else
        rm /home/${MCS_SERVER_USER}/mcptt.talkway.it/docker-compose.yml
        cp ./scripts/docker-compose.yml /home/${MCS_SERVER_USER}/mcptt.talkway.it/
        cd /home/${MCS_SERVER_USER}/mcptt.talkway.it/
        chown ${MCS_SERVER_USER}:${MCS_SERVER_USER} docker-compose.yml
    fi

    if [[ "${EXEC_INSTALL_DOCKER}" == "1" ]]; then
        install_docker
        if [[ ! ${?} == "0" ]]; then
            shutdown
        fi
    
        #configure_docker_logs_fluentd
    fi

    if [[ "${EXEC_INSTALL_DOCKER}" == "1" ]]; then
        install_docker_compose
        if [[ ! ${?} == "0" ]]; then
            shutdown
        fi
    fi

    docker_login

    docker-compose pull
    if [[ $? -eq 0 ]]; then
        docker-compose up -d
        if [[ $? -eq 0 ]]; then
            RES_CSC_IMAGES_INSTALL_SUCCESS=true

            docker image prune -f
        else
            warning "CSC Images installation might have failed"
            shutdown
        fi
    else
        warning "CSC Images installation might have failed"
        shutdown
    fi

    if [[ "${EXEC_SETUP_DB}" == "1" ]]; then
        if [[ "${RES_CSC_IMAGES_INSTALL_SUCCESS}" == true ]]; then
            sleep 10

            setup_database

        fi
    fi

    cd "${CURRENT_DIR}"

    if [[ "${EXEC_SETUP_FIREWALL}" == "1" ]]; then
        FIREWALLD_STATE=$(firewall-cmd --state)
        if [[ "${FIREWALLD_STATE}" == "running" ]]; then
            log "Opening Http and Https service on firewall"
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            firewall-cmd --reload
        fi
    fi
fi

if [[ "${EXEC_SETUP_TEST_CONFIGURATION}" == "1" ]]; then
    log "Waiting 10 seconds for permitting docker images to fully execute"

    sleep 10

    install_test_configuration 
    if [[ ${?} -eq 0 ]]; then
        RES_TEST_CONFIG_INSTALL_SUCCESS=true
    fi

    cd "${CURRENT_DIR}"
fi

docker logout

install_recap

echo ""
echo -e "${Cyan}--------------------------------------"
echo -e " SETUP COMPLETED"
echo -e "--------------------------------------${Color_Off}"
echo ""

exit 0
