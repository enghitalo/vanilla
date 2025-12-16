module repositories

import domain

pub struct DummyProductRepository {}

pub fn (repo DummyProductRepository) find_by_id(id string) !domain.Product {
	return error('not found')
}
pub fn (repo DummyProductRepository) create(product domain.Product) !domain.Product {
	return product
}
pub fn (repo DummyProductRepository) list() ![]domain.Product {
	return []domain.Product{}
}
