# Подгружаем переменные из .env.local
-include ../.env.local
export

# Цвета для вывода
YELLOW := $(shell tput setaf 3)
GREEN  := $(shell tput setaf 2)
RED    := $(shell tput setaf 1)
RESET  := $(shell tput sgr0)

.PHONY: help init plan apply destroy check-tools

help:
	@echo "$(YELLOW)Доступные команды:$(RESET)"
	@echo "  make init    - Инициализация бэкенда в Cloudflare R2"
	@echo "  make plan    - Просмотр изменений"
	@echo "  make apply   - Применение конфигурации"
	@echo "  make destroy - Удаление всей инфраструктуры"

init: check-tools
	@echo "$(GREEN)>>> Инициализация бэкенда в R2...$(RESET)"
	@terraform init \
		-backend-config="endpoints={s3=\"$(R2_ENDPOINT)\"}" \
		-backend-config="access_key=$(AWS_ACCESS_KEY_ID)" \
		-backend-config="secret_key=$(AWS_SECRET_ACCESS_KEY)" \
		-backend-config="skip_credentials_validation=true" \
		-backend-config="skip_region_validation=true" \
		-backend-config="skip_metadata_api_check=true" \
		-backend-config="use_path_style=true" \
		-backend-config="skip_requesting_account_id=true" \
		-reconfigure

plan: check-tools
	@echo "$(GREEN)>>> Планирование изменений...$(RESET)"
	@terraform plan

apply: check-tools
	@echo "$(GREEN)>>> Применение конфигурации...$(RESET)"
	@terraform apply -auto-approve

destroy:
	@echo "$(YELLOW)>>> ВНИМАНИЕ: Удаление инфраструктуры через 5 секунд...$(RESET)"
	@sleep 5
	@terraform destroy