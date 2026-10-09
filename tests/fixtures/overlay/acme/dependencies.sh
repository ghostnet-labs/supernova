# Fixture overlay dependency rows for the overlay tests.
SETUP_DEPENDENCIES+=(
  "work:acme|all|external|-|command|acme-external-tool"
  "work:acme|all|python|$WORK_DIR/requirements.txt|imports|json"
)
