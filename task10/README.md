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

# Задание 10.2
## Корзины (carts)
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

## Заказы (orders)
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

## Товары (products)
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