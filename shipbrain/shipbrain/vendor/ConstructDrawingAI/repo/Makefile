# Common developer tasks. Targets assume a POSIX shell (Linux/macOS/DGX/ARC); on
# Windows use the underlying `uv run ...` commands directly (see README).
.PHONY: help install test lint format typecheck check serve hooks audit clean bundle

help:
	@echo "install    create venv + install dev & backend extras"
	@echo "test       run the test suite"
	@echo "lint       ruff lint"
	@echo "format     black + ruff --fix"
	@echo "typecheck  mypy on the CIR"
	@echo "check      lint + typecheck + test"
	@echo "serve      run the FastAPI backend (reload)"
	@echo "hooks      install pre-commit hooks"
	@echo "audit      run the dataset license audit"
	@echo "bundle     write a portable full-history git bundle (move the repo, no remote)"
	@echo "clean      remove caches"

install:
	uv sync --extra dev --extra backend

test:
	uv run pytest

lint:
	uv run ruff check .

format:
	uv run black .
	uv run ruff check --fix .

typecheck:
	uv run mypy cir

check: lint typecheck test

serve:
	uv run uvicorn backend.app:app --reload

hooks:
	uv run pre-commit install

audit:
	uv run python -m datasets.audit

# Portable, full-history snapshot for moving the repo to another machine (e.g. the 4090)
# when no git remote is configured. Writes OUTSIDE the tree; clone it with
# `git clone ../ConstructDrawingAI.bundle "Drawing AI"`. Code only — data/weights travel by DVC.
bundle:
	git bundle create ../ConstructDrawingAI.bundle --all
	git bundle verify ../ConstructDrawingAI.bundle

clean:
	rm -rf .pytest_cache .mypy_cache .ruff_cache htmlcov .coverage
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
