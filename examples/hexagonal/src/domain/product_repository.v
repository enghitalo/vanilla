module domain

pub struct Product {
pub:
	id    string
	name  string
	price f64
}

pub interface ProductRepository {
	find_by_id(id string) !Product
	create(product Product) !Product
	list() ![]Product
}
