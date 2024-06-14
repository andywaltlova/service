# Put targets here if there is a risk that a target name might conflict with a filename.
# this list is probably overkill right now.
# See: https://www.gnu.org/software/make/manual/html_node/Phony-Targets.html
.PHONY: test test-unit test-e2e images run format verify

ARTIFACT_DIR := $(if $(ARTIFACT_DIR),$(ARTIFACT_DIR),tests/test_results)
TEST_TAGS := $(if $(TEST_TAGS),$(TEST_TAGS),"")
SUITE_ID := $(if $(SUITE_ID),$(SUITE_ID),"nosuite")
PROVIDER := $(if $(PROVIDER),$(PROVIDER),"openai")
MODEL := $(if $(MODEL),$(MODEL),"gpt-3.5-turbo")

images: ## Build container images
	scripts/build-container.sh

install-tools:	install-woke ## Install required utilities/tools
	@command -v pdm > /dev/null || { echo >&2 "pdm is not installed. Installing..."; pip install pdm; }

install-woke: ## Install woke, required for Inclusive Naming scan
	@command -v ./woke > /dev/null || { echo >&2 "woke is not installed. Installing..."; curl -sSfL https://git.io/getwoke | bash -s -- -b ./; }

pdm-lock-check: ## Check that the pdm.lock file is in a good shape
	pdm lock --check

install-deps: install-tools pdm-lock-check ## Install all required dependencies needed to run the service, according to pdm.lock
	pdm sync

install-deps-test: install-tools pdm-lock-check ## Install all required dev dependencies needed to test the service, according to pdm.lock
	pdm sync --dev

update-deps: ## Check pyproject.toml for changes, update the lock file if needed, then sync.
	pdm install
	pdm install --dev

run: ## Run the service locally
	python runner.py

test: test-unit test-integration test-e2e ## Run all tests

test-unit: ## Run the unit tests
	@echo "Running unit tests..."
	@echo "Reports will be written to ${ARTIFACT_DIR}"
	COVERAGE_FILE="${ARTIFACT_DIR}/.coverage.unit" python -m pytest tests/unit --cov=ols --cov-report term-missing --cov-report "json:${ARTIFACT_DIR}/coverage_unit.json" --junit-xml="${ARTIFACT_DIR}/junit_unit.xml"
	python scripts/transform_coverage_report.py "${ARTIFACT_DIR}/coverage_unit.json" "${ARTIFACT_DIR}/coverage_unit.out"
	scripts/codecov.sh "${ARTIFACT_DIR}/coverage_unit.out"

test-integration: ## Run integration tests tests
	@echo "Running integration tests..."
	@echo "Reports will be written to ${ARTIFACT_DIR}"
	COVERAGE_FILE="${ARTIFACT_DIR}/.coverage.integration" python -m pytest -m 'not redis' tests/integration --cov=ols --cov-report term-missing --cov-report "json:${ARTIFACT_DIR}/coverage_integration.json" --junit-xml="${ARTIFACT_DIR}/junit_integration.xml" --cov-fail-under=60
	python scripts/transform_coverage_report.py "${ARTIFACT_DIR}/coverage_integration.json" "${ARTIFACT_DIR}/coverage_integration.out"
	scripts/codecov.sh "${ARTIFACT_DIR}/coverage_integration.out"

check-coverage: test-unit test-integration  ## Unit tests and integration tests overall code coverage check
	coverage combine --keep "${ARTIFACT_DIR}/.coverage.unit" "${ARTIFACT_DIR}/.coverage.integration"
	# the threshold should be very high there, in theory it should reach 100%
	coverage report -m --fail-under=94

test-e2e: ## Run e2e tests - requires running OLS server
	@echo "Running e2e tests..."
	@echo "Reports will be written to ${ARTIFACT_DIR}"
	python -m pytest tests/e2e --durations=0 -o junit_suite_name="${SUITE_ID}" -m "${TEST_TAGS}" --junit-prefix="${SUITE_ID}" --junit-xml="${ARTIFACT_DIR}/junit_e2e_${SUITE_ID}.xml" \
	--eval_provider ${PROVIDER} --eval_model ${MODEL} --eval_out_dir ${ARTIFACT_DIR}

coverage-report:	test-unit ## Export unit test coverage report into interactive HTML
	coverage html --data-file="${ARTIFACT_DIR}/.coverage.unit"

check-types: ## Checks type hints in sources
	mypy --explicit-package-bases --disallow-untyped-calls --disallow-untyped-defs --disallow-incomplete-defs ols/

security-check: ## Check the project for security issues
	bandit -c pyproject.toml -r .

format: ## Format the code into unified format
	black .
	ruff check . --fix --per-file-ignores=tests/*:S101 --per-file-ignores=scripts/*:S101

verify:	install-woke install-deps-test ## Verify the code using various linters
	black . --check
	ruff check . --per-file-ignores=tests/*:S101 --per-file-ignores=scripts/*:S101
	./woke . --exit-1-on-failure

schema:	## Generate OpenAPI schema file
	python scripts/generate_openapi_schema.py docs/openapi.json

get-rag: ## Download a copy of the RAG embedding model and vector database
	podman create --replace --name tmp-rag-container quay.io/openshift-lightspeed/lightspeed-rag-content@sha256:6a238245ec7da232bf64af0be95b8f5a3eede8127f4f49a123d5271e35667fc9 true
	rm -rf vector_db embeddings_model
	podman cp tmp-rag-container:/rag/vector_db vector_db
	podman cp tmp-rag-container:/rag/embeddings_model embeddings_model
	podman rm tmp-rag-container

help: ## Show this help screen
	@echo 'Usage: make <OPTIONS> ... <TARGETS>'
	@echo ''
	@echo 'Available targets are:'
	@echo ''
	@grep -E '^[ a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ''
