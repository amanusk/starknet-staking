pub mod interface;

pub mod reward_supplier;

//convenient reference
pub use reward_supplier::RewardSupplier;
pub use interface::IRewardSupplier;

#[cfg(test)]
mod test;