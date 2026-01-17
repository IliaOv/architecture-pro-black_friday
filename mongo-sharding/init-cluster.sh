#!/bin/bash

echo "=== Initializing MongoDB Sharding Cluster ==="

# 1. Даем время контейнерам запуститься
echo "Waiting for containers to start..."
sleep 10

# 2. Инициализируем config сервер
echo "Initializing config server..."
docker exec configSrv mongosh --port 27017 --eval "
try {
  rs.initiate({
    _id: 'config_server',
    configsvr: true,
    members: [
      { _id: 0, host: 'configSrv:27017' }
    ]
  });
  print('Config server initialized');
} catch(e) {
  print('Config server already initialized: ' + e.message);
}
"

# Ждем инициализации config сервера
echo "Waiting for config server to become primary..."
sleep 10

# 3. Инициализируем shard1
echo "Initializing shard1..."
docker exec shard1 mongosh --port 27018 --eval "
try {
  rs.initiate({
    _id: 'shard1',
    members: [
      { _id: 0, host: 'shard1:27018' }
    ]
  });
  print('Shard1 initialized');
} catch(e) {
  print('Shard1 already initialized: ' + e.message);
}
"

# 4. Инициализируем shard2
echo "Initializing shard2..."
docker exec shard2 mongosh --port 27019 --eval "
try {
  rs.initiate({
    _id: 'shard2',
    members: [
      { _id: 0, host: 'shard2:27019' }
    ]
  });
  print('Shard2 initialized');
} catch(e) {
  print('Shard2 already initialized: ' + e.message);
}
"

# Даем время шардам инициализироваться
echo "Waiting for shards to initialize..."
sleep 15

# 5. Добавляем шарды в mongos_router
echo "Adding shards to mongos_router..."
docker exec mongos_router mongosh --port 27020 --eval "
print('Adding shards to mongos_router...');
try {
  sh.addShard('shard1/shard1:27018');
  print('✓ Added shard1');
} catch(e) {
  print('Shard1 already added or error: ' + e.message);
}

try {
  sh.addShard('shard2/shard2:27019');
  print('✓ Added shard2');
} catch(e) {
  print('Shard2 already added or error: ' + e.message);
}

// Включаем шардирование для базы данных
print('Enabling sharding for database somedb...');
try {
  sh.enableSharding('somedb');
  print('✓ Sharding enabled for somedb');
} catch(e) {
  print('Sharding already enabled or error: ' + e.message);
}

// Создаем и шардируем коллекцию
print('Creating and sharding collection helloDoc...');
try {
  sh.shardCollection('somedb.helloDoc', { name: 'hashed' });
  print('✓ Collection helloDoc sharded');
} catch(e) {
  print('Collection already sharded or error: ' + e.message);
}

// Проверяем статус
print('\\n=== Sharding Status ===');
printjson(sh.status());
"

echo "=== Cluster initialization complete! ==="
echo ""
echo "Connect to mongos_router: docker exec -it mongos_router mongosh --port 27020"
echo "Check sharding status: sh.status()"
echo "Use database: use somedb"
echo "Check collection: db.helloDoc.getShardDistribution()"