#!/bin/bash

# This is a test suite for the fluentd raw_tcp feature

source "$(dirname "${BASH_SOURCE[0]}" )/../hack/lib/init.sh"
source "${OS_O_A_L_DIR}/hack/testing/util.sh"
os::util::environment::use_sudo

FLUENTD_WAIT_TIME=${FLUENTD_WAIT_TIME:-$(( 2 * minute ))}

os::test::junit::declare_suite_start "test/raw-tcp"

update_current_fluentd() {
    # undeploy fluentd
    stop_fluentd "" $FLUENTD_WAIT_TIME 2>&1 | artifact_out

    # update configmap logging-fluentd
    # edit so we don't send to ES
    oc get configmap/logging-fluentd -o yaml | sed '/## matches/ a\
    <match **>\
      @type copy\
      @include configs.d/user/raw-tcp.conf\
    </match>' | oc replace -f -
      oc patch configmap/logging-fluentd --type=json --patch '[{ "op": "add", "path": "/data/raw-tcp.conf", "#": "generated config file raw-tcp.conf" }]' 2>&1
      oc patch configmap/logging-fluentd --type=json --patch '[{ "op": "replace", "path": "/data/raw-tcp.conf", "value": "\
  <store>\n\
   @type rawtcp\n\
   flush_interval 1\n\
    <server>\n\
      name logstash\n\
      host logstash.openshift-logging.svc.cluster.local\n\
      port 9400\n\
    </server>\n\
  </store>\n"}]'

    # redeploy fluentd
    start_fluentd true 2>&1 | artifact_out
    lpod=$( get_running_pod logstash )
    if [ -n "${lpod:-}" ] ; then
      os::cmd::try_until_text "oc logs $lpod 2>&1" ".*kubernetes.*" $FLUENTD_WAIT_TIME
    fi
    fpod=$( get_running_pod fluentd ) || :
    artifact_log update_current_fluentd
    get_fluentd_pod_log $fpod > $ARTIFACT_DIR/$fpod.log
}

create_forwarding_logstash() {
  oc apply -f $OS_O_A_L_DIR/hack/templates/logstash.yml
  # wait for logstash to start
  os::cmd::try_until_text "oc get pods -l component=logstash" "^logstash-.* Running " 360000
}

# save current fluentd daemonset
saveds=$( mktemp )
oc get daemonset logging-fluentd -o yaml > $saveds

# save current fluentd configmap
savecm=$( mktemp )
oc get configmap logging-fluentd -o yaml > $savecm

cleanup() {
  local return_code="$?"
  set +e
  if [ $return_code = 0 ] ; then
    mycmd=os::log::info
  else
    mycmd=os::log::error
  fi

  # dump the pod before we restart it
  if [ -n "${fpod:-}" ] ; then
    artifact_log cleanup
    get_fluentd_pod_log $fpod > $ARTIFACT_DIR/$fpod.cleanup.log 2>&1
  fi
  oc get pods 2>&1 | artifact_out
 
  stop_fluentd "${fpod:-}" $FLUENTD_WAIT_TIME 2>&1 | artifact_out
  if [ -n "${savecm:-}" -a -f "${savecm:-}" ] ; then
    oc replace --force -f $savecm 2>&1 | artifact_out
  fi
  if [ -n "${saveds:-}" -a -f "${saveds:-}" ] ; then
    oc replace --force -f $saveds 2>&1 | artifact_out
  fi

  $mycmd raw-tcp test finished at $( date )

  # Clean up only if it's still around
  oc delete service/logstash 2>&1 | artifact_out
  oc delete deploymentconfig/logstash 2>&1 | artifact_out

  start_fluentd true 2>&1 | artifact_out
  # this will call declare_test_end, suite_end, etc.
  os::test::junit::reconcile_output
  exit $return_code
}
trap "cleanup" EXIT

os::log::info Starting raw-tcp test at $( date )

# make sure fluentd is working normally
os::cmd::try_until_text "oc get pods -l component=fluentd" "^logging-fluentd-.* Running "
fpod=$( get_running_pod fluentd )
wait_for_fluentd_to_catch_up

create_forwarding_logstash
update_current_fluentd
