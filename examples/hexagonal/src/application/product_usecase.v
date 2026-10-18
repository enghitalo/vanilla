module application

import domain

pub struct ProductUseCase {
	repo domain.ProductRepository
}

pub fn new_product_usecase(repo domain.ProductRepository) ProductUseCase {
	return ProductUseCase{
		repo: repo
	}
}

// The methods take the use case by reference: a by-value receiver that returns
// a Result straight from a call through its interface field is copied to the
// heap on every call (docs/V_PERF_TOOLBOX.md, vlang/v#30856).
pub fn (p &ProductUseCase) add_product(name string, price f64) !domain.Product {
	product := domain.Product{
		id:    '' // generate UUID in infra
		name:  name
		price: price
	}
	return p.repo.create(product)
}

pub fn (p &ProductUseCase) list_products() ![]domain.Product {
	return p.repo.list()
}
