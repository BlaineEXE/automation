#!/usr/bin/env python3

import json
import os
import sys


TFSTATE_FILE = 'terraform.tfstate'


def error(message):
    sys.stderr.write("%s\n".format(message))
    sys.exit(1)


def get_addresses(compute_attributes, floating_ip_resource):
    addresses = {}
    # Assumes that if a node does not have a floating IP, that IP is on a public network
    if floating_ip_resource is not None:
        # A floating IP exists, so the node's floating IP is external
        addresses['publicIpv4'] = floating_ip_resource['primary']['attributes']['address']
        addresses['privateIpv4'] = compute_attributes['access_ip_v4']
    else:
        # A floating IP does not exist, so the node's public and private IPs are the same
        addresses['publicIpv4'] = compute_attributes['access_ip_v4']
        addresses['privateIpv4'] = compute_attributes['access_ip_v4']
    return addresses


if not os.path.isfile(TFSTATE_FILE):
    error("The Terraform state file '%d' could not be found.".format(TFSTATE_FILE))

tfstate_json = None
with open('terraform.tfstate') as tfstate_file:
    tfstate_json = json.load(tfstate_file)

modules = tfstate_json['modules']
resources = {}
for module in modules:
    resources.update(module['resources'])

environment = {
    'sshUser': 'root',
    'sshKey': os.path.join(os.getcwd(), '../misc-files/id_shared'),
    'minions': []
}

#
# Admin
#
compute_attributes = resources['openstack_compute_instance_v2.admin']['primary']['attributes']
floating_ip_resource = resources.get('openstack_networking_floatingip_v2.admin_ext', None)

addresses = get_addresses(compute_attributes, floating_ip_resource)
environment['minions'].append({
    'role': 'admin',
    'minionId': compute_attributes['id'].replace('-', ''),
    'fqdn': compute_attributes['name'],
    'index': '0',
    'addresses': addresses,
    'status': 'unused'
})
environment['dashboardExternalHost'] = addresses['publicIpv4']
environment['dashboardHost'] = addresses['privateIpv4']

index = 1
#
# Masters
#
for resource in resources:
    if 'openstack_compute_instance_v2.master' not in resource:
        continue  # resource is not a master
    compute_attributes = resources[resource]['primary']['attributes']
    # Get floatingip resource name for single master env (no indexing) and multiple master env
    floating_ip_resource_name = resource.replace(
        'openstack_compute_instance_v2.master',
        'openstack_networking_floatingip_v2.master_ext')
    floating_ip_resource = resources.get(floating_ip_resource_name, None)
    addresses = get_addresses(compute_attributes, floating_ip_resource)
    environment['minions'].append({
        'role': 'master',
        'minionId': compute_attributes['id'].replace('-', ''),
        'fqdn': compute_attributes['name'],
        'index': str(index),
        'addresses': addresses,
        'status': 'unused'
    })
    if index == 1:
        # Pick first master as k8s public endpoint
        environment['kubernetesExternalHost'] = addresses['publicIpv4']
    index += 1

#
# Workers
#
for resource in resources:
    if 'openstack_compute_instance_v2.worker' not in resource:
        continue  # resource is not a worker
    compute_attributes = resources[resource]['primary']['attributes']
    # Get floatingip resource name for single worker env (no indexing) and multiple worker env
    floating_ip_resource_name = resource.replace(
        'openstack_compute_instance_v2.worker',
        'openstack_networking_floatingip_v2.worker_ext')
    floating_ip_resource = resources.get(floating_ip_resource_name, None)
    environment['minions'].append({
        'role': 'worker',
        'minionId': compute_attributes['id'].replace('-', ''),
        'fqdn': compute_attributes['name'],
        'index': str(index),
        'addresses': get_addresses(compute_attributes, floating_ip_resource),
        'status': 'unused'
    })
    index += 1

print(json.dumps(environment, sort_keys=True, indent=4))
