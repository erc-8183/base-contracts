const { ethers } = require("hardhat");

/**
 * Deployment script for MultiPartyEvaluator
 * 
 * Usage:
 *   npx hardhat run scripts/deployMultiPartyEvaluator.js --network <network>
 * 
 * Environment Variables:
 *   - PRIVATE_KEY: Deployer private key (required for non-local networks)
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying MultiPartyEvaluator with account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // Deploy MultiPartyEvaluator
  const MultiPartyEvaluator = await ethers.getContractFactory("MultiPartyEvaluator");
  const evaluator = await MultiPartyEvaluator.deploy();
  await evaluator.waitForDeployment();

  const evaluatorAddress = await evaluator.getAddress();
  console.log("\nMultiPartyEvaluator deployed to:", evaluatorAddress);

  // Log deployment info
  console.log("\n=== Deployment Summary ===");
  console.log("Contract: MultiPartyEvaluator");
  console.log("Address:", evaluatorAddress);
  console.log("Deployer:", deployer.address);
  console.log("Network:", (await ethers.provider.getNetwork()).name);
  console.log("Block:", await ethers.provider.getBlockNumber());

  // Verify constants
  console.log("\n=== Contract Constants ===");
  console.log("COORDINATION_COMPLETE:", await evaluator.COORDINATION_COMPLETE());
  console.log("COORDINATION_REJECT:", await evaluator.COORDINATION_REJECT());

  // Return deployment info for verification
  return {
    evaluator: evaluatorAddress,
    deployer: deployer.address,
  };
}

// Execute deployment
main()
  .then((deploymentInfo) => {
    console.log("\n✅ Deployment successful!");
    console.log("\nTo verify on BaseScan:");
    console.log(`npx hardhat verify --network baseSepolia ${deploymentInfo.evaluator}`);
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  });
