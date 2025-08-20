#!/bin/bash
if [ -f roles/requirements.yml ]; then
  echo "Installing roles from roles/requirements.yml..."
  ansible-galaxy install -r roles/requirements.yml --force -p ./roles/
  echo "Roles installed successfully"
else
  echo "No roles/requirements.yml found. Skipping role install."
fi