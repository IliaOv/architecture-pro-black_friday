# 1. Метрики для выявления «горячих» шардов
## 1.1 Нагрузка и перекос трафика

Смотрим per-shard:

- opcounters.read / write
- latency.read / write
- cpu, iowait
- connections

```js
sh.status()                       // распределение чанков
db.serverStatus().opcounters      // read/write нагрузка
db.serverStatus().connections
```

### Сигнал проблемы:
один шард стабильно >50–60% read/write при равных объёмах данных.

## 1.2 Перекос по чанкам (data skew)
```js
db.getSiblingDB("config").chunks.aggregate([
  { $group: { _id: "$shard", chunks: { $sum: 1 } } }
])
```

**Хороший результат:** Количество чанков на всех шардах отличается на единицы или проценты. Балансировщик свою работу сделал.

**Плохой результат:** { "_id" : "shardA", "chunks" : 250 }, { "_id" : "shardB", "chunks" : 97 }. Один шард хранит в 2.5 раза больше данных, чем другой. Это перекос по данным. Нужно проверять выбранный ключ шардирования.

### Сигнал:
количество чанков ≈ равное, но нагрузка ≠ равная → проблема в access pattern, не в объёме данных. Нужно анализировать паттерны доступа.

## 1.3 Hot-query по категориям
```js
db.products.explain("executionStats")
  .find({ category: "Electronics" })
```

### Сигнал:
запросы идут в ограниченное число шардов → shard key не справляется с популярной категорией.

# 2. Автоматическое перераспределение (рекомендуется)
## 2.1 Включённый балансер
```js
sh.getBalancerState()
sh.setBalancerState(true)
```

### Балансер автоматически:
- мигрирует чанки
- снижает нагрузку на hot-shards

## 2.2 Предварительное шардирование (pre-splitting)

Для популярных категорий.
```js
for (let i = 0; i < 10; i++) {
  sh.splitAt(
    "mobile_world.products",
    { category: "Electronics", _id: ObjectId((i*10).toString().padEnd(24,"0")) }
  )
}
```

### Эффект:
нагрузка сразу распределяется по нескольким шардам. Вместо одного большого чанка "Electronics" мы получаем нсеколько маленьких чанков для этой категории.

## 2.3 Изменение shard key

Если категория стабильно «горячая», можно добавить подкатегории.
```js
// Было:
{ category: 1, _id: "hashed" }

//Стало:
{ category: 1, subcategory: 1, _id: "hashed" }
```

# 3. Метрики
### Обязательные алерты

- shard read/write > 40% общего трафика
    - Что измеряет: Распределение операций ввода-вывода между шардами.
- latency p95 по shard > X ms
    - Что измеряет: Задержку операций на каждом шарде на перцентиле 95%.
- migrations backlog > 0 долгое время
    - Что измеряет: Очередь операций перемещения чанков между шардами.
- jumbo chunks detected
    - Чанк, который превысил максимальный размер и не может быть разделен автоматически.
####  Как обнаружить:
```js
// Найти jumbo chunks
db.getSiblingDB("config").chunks.find({ jumbo: true })

// Или по размеру
db.getSiblingDB("config").chunks.aggregate([
  { $match: { size: { $gt: 100 * 1024 * 1024 } } } // >100MB
])
```


# Проблема hot-shard — это почти всегда проблема shard key + access pattern, а не балансера.
## Решается:
- мониторингом нагрузки,
- дроблением популярных диапазонов,
- дополнительной энтропией в shard key.


## Стратегия шардирования: Zoned Tag Sharding
**Принцип работы:**
- Товары категории «Электроника» распределяются по нескольким шардам с помощью теговых зон
- Каждая зона привязана к диапазону шард-ключа (например, по product_id или category_id)
- Позволяет контролировать физическое размещение данных на конкретных шардах

```js
// Создание зон для распределения категории «Электроника»
sh.addShardTag("shard1", "electronics_zone1")
sh.addShardTag("shard2", "electronics_zone2") 
sh.addShardTag("shard3", "electronics_zone3")

// Для остальных категорий - общая зона
sh.addShardTag("shard4", "other_categories")
sh.addShardTag("shard5", "other_categories")

// Привязка диапазонов к зонам (пример с category_id)
sh.addTagRange("mobile_world.products",
    { category_id: "electronics", product_id: MinKey },
    { category_id: "electronics", product_id: MaxKey },
    "electronics_zone1"
)
```

### Ключевые метрики
```js
// 1. Балансировка данных по шардам
db.adminCommand({ getShardDistribution: 1 })

// 2. Статистика операций по шардам
db.adminCommand({ getShardVersion: "mobile_world.products" })

// 3. Мониторинг нагрузки в реальном времени
use admin
db.currentOp().inprog.forEach(op => {
    if(op.shard) printjson(op)
})

// 4. Метрики через collStats
db.products.stats().shards
```
### Триггеры для действий:
1. CPU > 70% на шарде + операции > 10k/sec → Добавить шард в зону
2. Размер данных > 80% от самого маленького шарда → Балансировка чанков
3. 90% запросов к 10% данных → Создать составной шард-ключ
4. Latency > 200ms → Добавить реплику для чтения в зоне

### Меры
```js
// Автоматическое разделение при превышении размера
sh.enableSharding("mobile_world")
sh.shardCollection("mobile_world.products", 
    { category_id: 1, product_id: 1 },
    { unique: true }
)

// Настройка автоматического разделения
db.settings.update(
    { _id: "chunksize" },
    { $set: { value: 64 } }, // Размер чанка в MB
    { upsert: true }
)
```
