## Запускаем все по порядку
```shell
# Даем права на выполнение
chmod +x init-cluster.sh test-cluster.sh mongo-init.sh

# 1. Запускаем контейнеры
docker-compose up -d

# 2. Инициализируем кластер
./init-cluster.sh

# 3. Проверяем работу
./test-cluster.sh

# 4 Заполняем данными
./mongo-init.sh
```

## Ручная проверка работы
```shell
# Подключитесь к mongos
docker exec -it mongos_router mongosh --port 27020

# Выполните в mongosh:
# 1. Проверьте статус
sh.status()

# 2. Перейдите в нашу БД
use somedb

# 3. Проверьте коллекцию
db.helloDoc.getShardDistribution()
```