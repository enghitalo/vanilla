# Hexagonal Architecture in This Project

This project follows the Hexagonal Architecture (also known as Ports and Adapters) to ensure a clean separation between business logic and external systems such as databases and web frameworks.

## Key Concepts

- **Domain Layer**: Contains core business entities and repository interfaces. It is independent of any external technology.
- **Application Layer**: Implements use cases and orchestrates business logic using domain interfaces.
- **Infrastructure Layer**: Provides concrete implementations for external systems (e.g., databases, HTTP servers) and implements the interfaces defined in the domain layer.
- **Main (Composition Root)**: Wires together the application by injecting infrastructure implementations into the application and domain layers.

## Directory Structure

```
examples/hexagonal/
  src/
    domain/           # Business entities and repository interfaces
    application/      # Use cases
    infrastructure/   # Adapters for DB, HTTP, etc.
      database/       # DB connection and pooling
      http/           # HTTP server and middleware
      repositories/   # DB repository implementations
  main.v              # Composition root
```

## How It Works

- The **domain** layer defines interfaces (ports) such as `UserRepository`, `ProductRepository`, or `PaymentService`. These describe what your business logic needs, not how it is implemented.
- The **infrastructure** layer provides adapters for external systems (e.g., databases, payment providers like Stripe or PayPal, HTTP servers). These adapters implement the interfaces defined in the domain layer.
- The **application** layer uses only the interfaces, remaining agnostic to the actual technology or provider.
- The **main** function wires everything together, choosing which infrastructure implementation to use and injecting it into the application.

## Why External Integrations Belong in Infrastructure

External systems (databases, payment gateways, messaging services, etc.) are subject to change and are not part of your core business logic. By placing their adapters in the infrastructure layer:

- **Separation of concerns**: Your domain and application layers remain focused on business rules, not technology details.
- **Testability**: You can test your business logic with mock implementations, without needing real external systems.
- **Flexibility**: You can swap out or add new providers (e.g., switch from Stripe to PayPal) by changing only the infrastructure layer.
- **Maintainability**: Changes to external APIs or libraries are isolated from your core logic.

## Extending with Payment Providers (Example)

Suppose you want to support payments via Stripe and PayPal:

1. **Define a PaymentService interface in the domain layer**

```v
// domain/payment.v
pub interface PaymentService {
  charge(amount_in_cents int, currency string, source string) !PaymentResult
  refund(payment_id string) !bool
}
```

2. **Implement adapters in the infrastructure layer**

- `infrastructure/payments/stripe_payment_service.v` implements `PaymentService` for Stripe.
- `infrastructure/payments/paypal_payment_service.v` implements `PaymentService` for PayPal.

3. **Inject the desired implementation in main**

- The main function wires up the correct payment adapter and injects it into the application layer.

## Example

- `domain/user.v` defines the `UserRepository` interface.
- `infrastructure/repositories/pg_user_repository.v` implements `UserRepository` for PostgreSQL.
- `main.v` selects and injects the desired repository implementation.
- `domain/payment.v` defines the `PaymentService` interface.
- `infrastructure/payments/stripe_payment_service.v` implements Stripe integration.

---
