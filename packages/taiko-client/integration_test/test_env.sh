#!/bin/bash

source internal/docker/docker_env.sh
source scripts/common.sh

# get deployed contract address.
DEPLOYMENT_JSON=$(cat ../protocol/deployments/deploy_l1.json)
export TAIKO_L1_ADDRESS=$(echo "$DEPLOYMENT_JSON" | jq '.taiko' | sed 's/\"//g')
export TAIKO_L2_ADDRESS=0x1670010000000000000000000000000000010001
export TAIKO_TOKEN_ADDRESS=$(echo "$DEPLOYMENT_JSON" | jq '.taiko_token' | sed 's/\"//g')
export SEQUENCER_REGISTRY_ADDRESS=$(echo "$DEPLOYMENT_JSON" | jq '.sequencer_registry' | sed 's/\"//g')
export TIMELOCK_CONTROLLER=$(echo "$DEPLOYMENT_JSON" | jq '.timelock_controller' | sed 's/\"//g')
export GUARDIAN_PROVER_CONTRACT=$(echo "$DEPLOYMENT_JSON" | jq '.guardian_prover' | sed 's/\"//g')
export GUARDIAN_PROVER_MINORITY=$(echo "$DEPLOYMENT_JSON" | jq '.guardian_prover_minority' | sed 's/\"//g')
export L1_CONTRACT_OWNER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export L1_SECURITY_COUNCIL_PRIVATE_KEY=0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97
export L1_PROPOSER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export L2_SUGGESTED_FEE_RECIPIENT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export L1_PROVER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export TREASURY=0x1670010000000000000000000000000000010001
export VERBOSITY=3

# show the integration test environment variables.
# L1_BEACON=$L1_BEACON
echo "RUN_TESTS=true
L1_HTTP=$L1_HTTP
L1_WS=$L1_WS
L2_SUGGESTED_FEE_RECIPIENT=$L2_SUGGESTED_FEE_RECIPIENT
L2_HTTP=$L2_HTTP
L2_WS=$L2_WS
L2_AUTH=$L2_AUTH
TAIKO_L1_ADDRESS=$TAIKO_L1_ADDRESS
TAIKO_L2_ADDRESS=$TAIKO_L2_ADDRESS
TAIKO_TOKEN_ADDRESS=$TAIKO_TOKEN_ADDRESS
TIMELOCK_CONTROLLER=$TIMELOCK_CONTROLLER
SEQUENCER_REGISTRY_ADDRESS=$SEQUENCER_REGISTRY_ADDRESS
ROLLUP_ADDRESS_MANAGER=$ROLLUP_ADDRESS_MANAGER
GUARDIAN_PROVER_CONTRACT=$GUARDIAN_PROVER_CONTRACT
GUARDIAN_PROVER_MINORITY=$GUARDIAN_PROVER_MINORITY
L1_CONTRACT_OWNER_PRIVATE_KEY=$L1_CONTRACT_OWNER_PRIVATE_KEY
L1_SECURITY_COUNCIL_PRIVATE_KEY=$L1_SECURITY_COUNCIL_PRIVATE_KEY
L1_PROPOSER_PRIVATE_KEY=$L1_PROPOSER_PRIVATE_KEY
L1_PROVER_PRIVATE_KEY=$L1_PROVER_PRIVATE_KEY
TREASURY=$TREASURY
JWT_SECRET=$JWT_SECRET
VERBOSITY=$VERBOSITY" > integration_test/.env
