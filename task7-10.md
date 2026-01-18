# Задание 7
## 1. Коллекция orders
### Схема
```js
{
  _id: ObjectId,        // order_id
  user_id: ObjectId,    // идентификатор клиента
  created_at: Date,

  items: [
    {
      product_id: ObjectId,
      category: String,
      price: Number,
      quantity: Number
    }
  ],

  status: String,
  total_amount: Number,
  geo_zone: String
}
```

### Индексы
```js
{ user_id: 1, created_at: -1 }  // история заказов пользователя
{ _id: 1 }          // получение статуса заказа
```

### Стратегия шардирования

**Шард-ключ:** `{ user_id: "hashed" }`

**Тип шардирования:** Хэшированное шардирование (based sharding)

**Обоснование:**
- все заказы одного пользователя находятся в одном шарде
- hash даёт равномерное распределение записей и устраняет hot-shard при массовом создании заказов.
- по гео было бы неравномерное распределение

### Команды MongoDB
```js
 // включаем шардирование БД
sh.enableSharding("mobile_world")

use mobile_world

// индекс под shard key
db.orders.createIndex({ user_id: "hashed" })

db.orders.createIndex({ user_id: 1, created_at: -1 })
db.orders.createIndex({ _id: 1 })

// включаем шардирование коллекции
sh.shardCollection(
  "mobile_world.orders",
  { user_id: "hashed" }
)
```

## 2. Коллекция products
```js
{
  _id: ObjectId,        // product_id
  name: String,
  category: String,
  price: Number,

  stock_by_geo: [
    {
      geo_zone: String,
      stock: Number
    }
  ],

  attributes: {
    color: String,
    size: String
  }
}
```

### Индексы
```js
{ category: 1, price: 1 }                           // поиск и фильтрация
{ _id: 1 }                                          // страница товара
{ stock_by_geo.geo_zone: 1, stock_by_geo.stock: 1 } // остатки
```

### Стратегия шардирования

**Шард-ключ:** `{ category: 1, _id: "hashed" }`

**Тип шардирования:** range + hash

*Это compound shard key*, где:
- первый ключ отвечает за локализацию запросов
- второй — за баланс нагрузки

**Обоснование:**
- только { _id: "hashed" } → плохо для поиска по категориям
- category (range) — группирует товары логически (каталог)
- _id (hashed) — равномерно распределяет товары внутри категории
- удобный поиск по category
- массовые обновления остатков → нет перегрузки одного шарда

### Команды MongoDB
```js
use mobile_world

db.products.createIndex({ _id: 1 })
db.products.createIndex({ "stock_by_geo_zone.geo_zone": 1, "stock_by_geo_zone.stock": 1 })

// индекс должен совпадать с shard key
db.products.createIndex({ category: 1, _id: "hashed" })

// шардирование коллекции
sh.shardCollection(
  "mobile_world.products",
  { category: 1, _id: "hashed" }
)
```

## 3. Коллекция carts
```js
{
  _id: ObjectId,                  // cart_id

  user_id: ObjectId | null,
  session_id: String | null,

  items: [
    {
      product_id: ObjectId,
      quantity: Number
    }
  ],

  status: "active" | "ordered" | "abandoned",

  created_at: Date,
  updated_at: Date,
  expires_at: Date
}
```

### Индексы
```js
{ user_id: 1, status: 1 }
{ session_id: 1, status: 1 }
{ expires_at: 1 }
```

### Стратегия шардирования

**Шард-ключ:** 
- `{ session_id: "hashed" }` - если гостевые корзины составляют большую часть трафика
- `{ user_id: "hashed" }` - подходит, если >80% трафика — авторизованные пользователи.
**Тип шардирования:** hash 

**Обоснование:**
- Каждая сессия независимо распределяется по шардам → высокая write-нагрузка масштабируется линейно.

### Команды MongoDB
```js
use mobile_world

db.carts.createIndex({ user_id: 1, status: 1 })
db.carts.createIndex({ session_id: 1, status: 1 })
db.carts.createIndex({ expires_at: 1 })

// индекс под shard key
db.carts.createIndex({ session_id: "hashed" })

// включаем шардирование
sh.shardCollection(
  "mobile_world.carts",
  { session_id: "hashed" }
)
```

---
# Задание 8
## 1. Метрики для выявления «горячих» шардов
### 1.1 Нагрузка и перекос трафика

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

### 1.2 Перекос по чанкам (data skew)
```js
db.getSiblingDB("config").chunks.aggregate([
  { $group: { _id: "$shard", chunks: { $sum: 1 } } }
])
```

**Хороший результат:** Количество чанков на всех шардах отличается на единицы или проценты. Балансировщик свою работу сделал.

**Плохой результат:** { "_id" : "shardA", "chunks" : 250 }, { "_id" : "shardB", "chunks" : 97 }. Один шард хранит в 2.5 раза больше данных, чем другой. Это перекос по данным. Нужно проверять выбранный ключ шардирования.

### Сигнал:
количество чанков ≈ равное, но нагрузка ≠ равная → проблема в access pattern, не в объёме данных. Нужно анализировать паттерны доступа.

### 1.3 Hot-query по категориям
```js
db.products.explain("executionStats")
  .find({ category: "Electronics" })
```

### Сигнал:
запросы идут в ограниченное число шардов → shard key не справляется с популярной категорией.

## 2. Автоматическое перераспределение
### 2.1 Включённый балансер
```js
sh.getBalancerState()
sh.setBalancerState(true)
```

### Балансер автоматически:
- мигрирует чанки
- снижает нагрузку на hot-shards

### 2.2 Предварительное шардирование (pre-splitting)

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

### 2.3 Изменение shard key

Если категория стабильно «горячая», можно добавить подкатегории.
```js
// Было:
{ category: 1, _id: "hashed" }

//Стало:
{ category: 1, subcategory: 1, _id: "hashed" }
```

## 3. Метрики
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

**Проблема hot-shard — это почти всегда проблема shard key + access pattern, а не балансера.**
## Решается:
- мониторингом нагрузки,
- дроблением популярных диапазонов,
- дополнительной энтропией в shard key.

---

# Задание 9

### products
| Операция чтения                              | Primary | Secondary |
| -------------------------------------------- | ------- | --------- |
| Каталог товаров (category, price)            |         | ✅         |
| Страница товара (описание, атрибуты)         |         | ✅         |
| Проверка остатка перед добавлением в корзину |         | ✅         |
| Проверка остатка при оформлении заказа       | ✅       |           |
| Служебные отчёты / аналитика                 |         | ✅         |

#### Обоснование:
- Консистентность
    - Остатки товара участвуют в критическом бизнес-решении (можно ли продать).
    - Любая неточность при финальной проверке → риск oversell.
- Частота обновлений
    - Остатки обновляются очень часто (каждая покупка).
    - Репликационный lag на secondary неизбежен.
- Бизнес-логика
    - Каталог и карточка товара допускают eventual consistency.
    - Финальная проверка остатков перед заказом требует strong consistency.
- Итог:
    - UI-чтения → secondary
    - Проверка остатков при заказе → primary

### carts
| Операция чтения                            | Primary | Secondary |
| ------------------------------------------ | ------- | --------- |
| Получение активной корзины                 | ✅       |           |
| Проверка содержимого корзины перед заказом | ✅       |           |
| Отображение корзины (read-only, UI)        |         | ✅         |
| Аналитика брошенных корзин                 |         | ✅         |

#### Обоснование:
- Консистентность
    - Корзина — временное, но stateful-состояние пользователя.
    - Несогласованность ведёт к потере или дублированию товаров.
- Частота обновлений
    - Частые изменения (add/remove/update quantity).
    - Состояние может меняться несколько раз в секунду.
- Бизнес-логика
    - Пользователь ожидает видеть текущее состояние корзины.
    - Устаревшее состояние → плохой UX и ошибки при заказе.
- Итог:
    - Все бизнес-критичные чтения → primary
    - Только read-only отображение (без принятия решений) → secondary

### orders
| Операция чтения                             | Primary | Secondary |
| ------------------------------------------- | ------- | --------- |
| Получение статуса заказа (после оформления) | ✅       |           |
| История заказов пользователя                |         | ✅         |
| Админ/аналитические отчёты                  |         | ✅         |
| Валидация заказа в бизнес-процессе          | ✅       |           |

#### Обоснование:
- Консистентность
    - Статус заказа влияет на дальнейшие действия (оплата, доставка, поддержка).
    - Неверный статус подрывает доверие пользователя.
- Частота обновлений
    - Обновления статуса происходят реже, чем корзины или остатки.
    - Но каждое обновление бизнес-критично.
- Бизнес-логика
    - Сразу после действия пользователя (оплата, отмена) статус должен быть точным.
    - История заказов — информационный сценарий.
- Итог:
    - Получение текущего статуса → primary
    - История заказов / отчёты → secondary

## Допустимая задержка репликации (replication lag)
| Коллекция | Secondary lag (допустимо) |
| --------- | ------------------------- |
| products  | до **5–10 сек**           |
| carts     | до **1–2 сек**            |
| orders    | до **2–5 сек**            |

---

# Задание 10.1

## 1. Классификация данных по критичности
Критерии
- Целостность (strong consistency)
- Скорость записи/чтения
- Допустимость eventual consistency
- Геораспределённость
- Write-heavy / read-heavy профиль

| Данные                        | Критичность целостности | Нагрузка                    | Cassandra подходит  | Почему                         |
| ----------------------------- | ----------------------- | --------------------------- | ------------------- | ------------------------------ |
| carts (Корзины)               | Средняя                 | Очень высокая (write-heavy) | ✅ Да               | Eventual consistency допустима |
| Пользовательские сессии       | Низкая                  | Очень высокая               | ✅ Да               | Потеря данных некритична       |
| История заказов (orders)      | Низко-средняя           | Read-heavy                  | ✅ Да               | Исторические данные            |
| products (Товары) (read-only) | Низкая                  | Read-heavy                  | ✅ Да               | Нет строгих инвариантов        |
| Заказы (orders) (создание)    | **Высокая**             | Средняя                     | ❌ Нет              | Требует транзакционности       |
| Остатки товаров               | **Критическая**         | Write-heavy                 | ❌ Нет              | Риск oversell                  |
| Платежи                       | **Критическая**         | Низкая                      | ❌ Нет              | ACID обязателен                |

## 2. Где Cassandra имеет смысл (обоснование)
Использовать её нужно:
- для write-heavy, session-like, append-only данных;
- не как единственный источник истины, а как read/write store под нагрузку.

### 2.1 Корзины
**Почему Cassandra:**
- Огромное количество write-операций.
- Потеря последнего апдейта корзины допустима.
- Отлично масштабируется линейно.
- TTL — нативный механизм.

### 2.2 Пользовательские сессии
**Почему Cassandra:**
- Данные краткоживущие.
- Не требуют строгой согласованности.

### 2.3 История заказов (read-model)
**Почему Cassandra:**
- Данные краткоживущие.
- Не требуют строгой согласованности.

### 2.4 Каталог товаров (read-model)
**Почему Cassandra:**
- Высокий read QPS.
- Данные редко меняются.
- Легко кэшируются и реплицируются глобально.

## 3. Где Cassandra не имеет смысл (обоснование)
### 3.1 Создание заказа
**Почему нет:**
- Нет multi-row ACID-транзакций.
- Сложно гарантировать exactly-once.

### 3.2 Остатки товаров
**Почему нет:**
- Требуется строгая консистентность.

## Задание 10.2
### Корзины (carts)
```sql
CREATE TABLE carts_by_session (
    session_id text,
    updated_at timestamp,
    product_id uuid,
    quantity int,
    PRIMARY KEY ((session_id), updated_at, product_id)
) WITH CLUSTERING ORDER BY (updated_at DESC)
  AND default_time_to_live = 86400;  -- TTL 24 часа
```
### Ключи
- Partition key: `session_id`
- Clustering keys: `updated_at, product_id`

### Обоснование
- `session_id` → равномерное распределение
- все операции идут в одну партицию
- ускоряет запросы с фильтрацией и сортировкой
- updated_at, product_id → clustering, обеспечивает сортировку последних изменений
- TTL автоматически удаляет старые корзины

### Заказы (orders)
```sql
CREATE TABLE orders (
    user_id uuid,
    created_at timestamp,
    order_id uuid,
    status text,
    total_amount decimal,
    PRIMARY KEY ((user_id), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC);
```
### Ключи
- Partition key: `user_id`
- Clustering keys: `created_at, order_id`
### Обоснование
- `user_id` → равномерное распределение
- все заказы клиента в одной партиции - локализация запросов
- created_at → clustering key для сортировки последних заказов, ускоряет запросы с фильтрацией и сортировкой

### Товары (products)
```sql
CREATE TABLE products (
    category text,
    bucket int,
    product_id uuid,
    name text,
    price decimal,
    attributes map<text, text>,
    PRIMARY KEY ((category, bucket), product_id)
);
CREATE TABLE product_stock  (
    product_id uuid,
    geo_zone text,
    stock  decimal,
    PRIMARY KEY ((product_id, geo_zone))
);
```
### Ключи
- Partition key: `category, bucket`
```
bucket = hash(product_id) % N
```
- Clustering keys: `product_id`
### Обоснование
- Популярная категория разбивается на N партиций
- Нагрузка распределяется равномерно
- product_id → clustering key для уникальности и сортировки

# Задание 10.3
| Сущность                                   | Основные требования                                           | Выбранная стратегия          | Обоснование                                                                                                                                                                                                                                                 |
| ------------------------------------------ | ------------------------------------------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Корзины (carts)**                        | Быстрое write/read, TTL, eventual consistency допустима       | Hinted Handoff + Read Repair | Write-heavy, можно допустить кратковременное рассогласование. Hinted Handoff минимизирует потерю данных при временной недоступности ноды. Read Repair исправляет stale данные при чтении. Latency критична → Anti-Entropy не используется в синхронной path |
| **Сессии (sessions)**                      | Временные данные, высокое write-QPS, low criticality          | Hinted Handoff               | Допустим кратковременный рассинк.                                                                                                                                         |
| **История заказов (orders_by_user)**       | Append-only, read-heavy, eventual consistency допустима       | Read Repair + Anti-Entropy   | Синхронные writes не критичны, но важно со временем исправить рассогласование для аналитики. Anti-Entropy repair выполняется фоново. Latency read не сильно страдает.                                                                                       |
| **Каталог товаров (products_by_category)** | Read-heavy, редко обновляется, критичность целостности низкая | Anti-Entropy + Read Repair   | Изменения редки → Hinted Handoff не нужен. Фоновые repair/Read Repair обеспечивают eventual consistency без влияния на read latency.                                                                                                                        |

### Обоснование с точки зрения latency vs. consistency
- Latency-critical, write-heavy (carts, sessions) → используем Hinted Handoff; минимизируем задержки, допускаем временную рассогласованность.
- Read-heavy, append-only (orders, products) → используем Read Repair и Anti-Entropy; write latency менее критична, но eventual consistency должна быть гарантирована со временем.
- Фоновые операции (Anti-Entropy repair) не влияют на критичные path и исправляют рассогласование долговременно.