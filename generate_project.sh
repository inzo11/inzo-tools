#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="inzo-tools-with-ai"
ZIPNAME="${ROOT_DIR}.zip"
echo "Generating project in ./${ROOT_DIR} ..."

if [ -d "${ROOT_DIR}" ]; then
  echo "Directory ${ROOT_DIR} already exists. Aborting to avoid overwrite."
  echo "If you want to overwrite, delete the directory and run this script again."
  exit 1
fi

mkdir -p "${ROOT_DIR}"

# create README
cat > "${ROOT_DIR}/README.md" <<'EOF'
# INZO TOOLS WITH AI

Project scaffold for INZO TOOLS WITH AI (smart contracts, auditor, frontend, backend).
Follow instructions in README to install dependencies, run tests, and deploy.
EOF

# minimal package.json
cat > "${ROOT_DIR}/package.json" <<'EOF'
{
  "name": "inzo-tools-with-ai",
  "version": "1.0.0",
  "private": true,
  "workspaces": [
    "auditor",
    "frontend/web",
    "explorer-backend"
  ],
  "scripts": {
    "test": "npx hardhat test"
  }
}
EOF

# hardhat config
cat > "${ROOT_DIR}/hardhat.config.js" <<'EOF'
require("@nomiclabs/hardhat-ethers");
require("dotenv").config();
module.exports = {
  solidity: "0.8.17",
  networks: {
    hardhat: {},
    sepolia: {
      url: process.env.SEPOLIA_RPC || "",
      accounts: process.env.DEPLOYER_PK ? [process.env.DEPLOYER_PK] : []
    },
    mainnet: {
      url: process.env.MAINNET_RPC || "",
      accounts: process.env.DEPLOYER_PK ? [process.env.DEPLOYER_PK] : []
    }
  },
  etherscan: { apiKey: process.env.ETHERSCAN_API_KEY || "" }
};
EOF

# create contracts dir and key files (short set; expand as needed)
mkdir -p "${ROOT_DIR}/contracts"

cat > "${ROOT_DIR}/contracts/DeploymentFactory.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
contract DeploymentFactory is Ownable {
    address public treasury;
    address public feeToken;
    uint256 public feeAmountNative;
    uint256 public feeAmountToken;
    bool public enabled;
    event Deployed(address indexed deployer, address indexed deployed, bytes32 indexed salt, uint256 valuePaid, address feeToken, uint256 feeAmount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeeConfigUpdated(address feeToken, uint256 feeAmountNative, uint256 feeAmountToken);
    event EnabledUpdated(bool enabled);
    modifier whenEnabled() { require(enabled, "factory disabled"); _; }
    constructor(address _treasury, address _feeToken, uint256 _feeAmountNative, uint256 _feeAmountToken) {
        require(_treasury != address(0), "treasury zero");
        treasury = _treasury;
        feeToken = _feeToken;
        feeAmountNative = _feeAmountNative;
        feeAmountToken = _feeAmountToken;
        enabled = true;
    }
    function deployWithNativeFee(bytes calldata initCode, bytes32 salt) external payable whenEnabled returns (address deployedAddress) {
        require(msg.value >= feeAmountNative, "insufficient fee");
        (bool sent, ) = payable(treasury).call{value: feeAmountNative}("");
        require(sent, "fee transfer failed");
        uint256 excess = msg.value - feeAmountNative;
        if (excess > 0) {
            (bool r, ) = payable(msg.sender).call{value: excess}("");
            require(r, "refund failed");
        }
        deployedAddress = _deployCreate2(initCode, salt);
        emit Deployed(msg.sender, deployedAddress, salt, feeAmountNative, address(0), feeAmountNative);
    }
    function deployWithTokenFee(bytes calldata initCode, bytes32 salt) external whenEnabled returns (address deployedAddress) {
        require(feeToken != address(0), "fee token not configured");
        require(feeAmountToken > 0, "fee token amount 0");
        bool ok = IERC20(feeToken).transferFrom(msg.sender, treasury, feeAmountToken);
        require(ok, "token transfer failed");
        deployedAddress = _deployCreate2(initCode, salt);
        emit Deployed(msg.sender, deployedAddress, salt, 0, feeToken, feeAmountToken);
    }
    function _deployCreate2(bytes calldata initCode, bytes32 salt) internal returns (address addr) {
        require(initCode.length != 0, "empty initCode");
        bytes memory code = initCode;
        assembly {
            let encoded_data := add(code, 0x20)
            let encoded_size := mload(code)
            addr := create2(0, encoded_data, encoded_size, salt)
        }
        require(addr != address(0), "create2 failed");
    }
    function computeAddress(bytes calldata initCode, bytes32 salt) external view returns (address) {
        bytes32 initCodeHash = keccak256(initCode);
        bytes32 raw = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));
        return address(uint160(uint256(raw)));
    }
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero");
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }
    function configureFee(address _feeToken, uint256 _feeAmountNative, uint256 _feeAmountToken) external onlyOwner {
        feeToken = _feeToken;
        feeAmountNative = _feeAmountNative;
        feeAmountToken = _feeAmountToken;
        emit FeeConfigUpdated(_feeToken, _feeAmountNative, _feeAmountToken);
    }
    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
    function withdrawETH(address to, uint256 amount) external onlyOwner {
        (bool sent,) = payable(to).call{value: amount}("");
        require(sent, "withdraw failed");
    }
    function setEnabled(bool _enabled) external onlyOwner {
        enabled = _enabled;
        emit EnabledUpdated(_enabled);
    }
    receive() external payable { revert("send not allowed"); }
    fallback() external payable { revert("fallback not allowed"); }
}
EOF

# minimal test helper contracts
cat > "${ROOT_DIR}/contracts/SimpleStorage.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
contract SimpleStorage {
    uint256 public value;
    address public owner;
    event ValueSet(uint256 newValue);
    constructor(uint256 _initial) { value = _initial; owner = msg.sender; }
    function set(uint256 v) external { value = v; emit ValueSet(v); }
}
EOF

cat > "${ROOT_DIR}/contracts/TokenMock.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract TokenMock is ERC20 {
    constructor(string memory name_, string memory sym_) ERC20(name_, sym_) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
EOF

# scripts
mkdir -p "${ROOT_DIR}/scripts"
cat > "${ROOT_DIR}/scripts/deploy_factory.js" <<'EOF'
require("dotenv").config();
const hre = require("hardhat");
async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  const treasury = process.env.TREASURY_ADDRESS || deployer.address;
  const Factory = await hre.ethers.getContractFactory("DeploymentFactory");
  const nativeFee = hre.ethers.utils.parseEther(process.env.FACTORY_FEE_NATIVE || "0.01");
  const factory = await Factory.deploy(treasury, hre.ethers.constants.AddressZero, nativeFee, 0);
  await factory.deployed();
  console.log("DeploymentFactory at:", factory.address);
}
main().catch((e) => { console.error(e); process.exit(1); });
EOF

# tests
mkdir -p "${ROOT_DIR}/test"
cat > "${ROOT_DIR}/test/DeploymentFactory.test.js" <<'EOF'
const { expect } = require("chai");
const { ethers } = require("hardhat");
describe("DeploymentFactory", function () {
  let factory;
  let owner;
  let user;
  let treasury;
  const nativeFee = ethers.utils.parseEther("0.01");
  beforeEach(async function () {
    [owner, user, treasury] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("DeploymentFactory");
    factory = await Factory.deploy(treasury.address, ethers.constants.AddressZero, nativeFee, 0);
    await factory.deployed();
  });
  it("reverts on insufficient native fee", async function () {
    const Simple = await ethers.getContractFactory("SimpleStorage");
    const initTx = Simple.getDeployTransaction(123);
    const initCode = initTx.data;
    const salt = ethers.utils.formatBytes32String("s1");
    await expect(factory.connect(user).deployWithNativeFee(initCode, salt, { value: ethers.utils.parseEther("0.001") }))
      .to.be.revertedWith("insufficient fee");
  });
  it("deploys contract with native fee", async function () {
    const Simple = await ethers.getContractFactory("SimpleStorage");
    const initTx = Simple.getDeployTransaction(555);
    const initCode = initTx.data;
    const salt = ethers.utils.formatBytes32String("s2");
    const computed = await factory.computeAddress(initCode, salt);
    await expect(() => factory.connect(user).deployWithNativeFee(initCode, salt, { value: nativeFee }))
      .to.changeEtherBalances([user, treasury], [nativeFee.mul(-1), nativeFee]);
    const deployed = await ethers.getContractAt("SimpleStorage", computed);
    expect(await deployed.value()).to.equal(555);
  });
});
EOF

# frontend skeleton
mkdir -p "${ROOT_DIR}/frontend/web/components"
cat > "${ROOT_DIR}/frontend/web/components/FactoryDeploy.jsx" <<'EOF'
import React, { useState } from "react";
import { ethers } from "ethers";
export default function FactoryDeploy({ factoryAddress }) {
  const [initCode, setInitCode] = useState("");
  const [salt, setSalt] = useState("");
  const [status, setStatus] = useState("");
  const [txHash, setTxHash] = useState("");
  const [computedAddr, setComputedAddr] = useState("");
  const deploy = async () => {
    if (!window.ethereum) return alert("Connect wallet");
    if (!initCode) return alert("Please provide initCode");
    try {
      setStatus("Preparing tx...");
      const provider = new ethers.providers.Web3Provider(window.ethereum);
      await provider.send("eth_requestAccounts", []);
      const signer = provider.getSigner();
      const factory = new ethers.Contract(factoryAddress, ["function deployWithNativeFee(bytes initCode, bytes32 salt) payable returns (address)","function computeAddress(bytes initCode, bytes32 salt) view returns (address)"], signer);
      const saltBytes = salt ? ethers.utils.formatBytes32String(salt) : ethers.utils.formatBytes32String(Math.random().toString());
      const fee = ethers.utils.parseEther("0.01");
      const tx = await factory.deployWithNativeFee(initCode, saltBytes, { value: fee });
      setStatus("Waiting...");
      const receipt = await tx.wait();
      setTxHash(receipt.transactionHash);
      const comp = await factory.computeAddress(initCode, saltBytes);
      setComputedAddr(comp);
      setStatus("Deployed");
    } catch (err) {
      console.error(err);
      setStatus("Deploy failed: " + (err.message || err));
    }
  };
  return (
    <div>
      <h3>Factory Deploy (Pay Fee)</h3>
      <textarea value={initCode} onChange={(e)=>setInitCode(e.target.value)} placeholder="0x..." rows={6} cols={70} />
      <input value={salt} onChange={(e)=>setSalt(e.target.value)} placeholder="optional salt" />
      <button onClick={deploy}>Deploy (pay fee)</button>
      <div>Status: {status}</div>
      {txHash && <div>Tx: {txHash}</div>}
      {computedAddr && <div>Computed: {computedAddr}</div>}
    </div>
  );
}
EOF

# create make_zip
cat > "${ROOT_DIR}/make_zip.sh" <<'EOF'
#!/usr/bin/env bash
ZIPNAME="inzo-tools-with-ai.zip"
echo "Creating zip ${ZIPNAME}..."
zip -r ${ZIPNAME} contracts scripts test frontend README.md hardhat.config.js package.json || exit 1
echo "Created ${ZIPNAME}"
EOF
chmod +x "${ROOT_DIR}/make_zip.sh"

# final zip
(
  cd "${ROOT_DIR}"
  if ! command -v zip >/dev/null 2>&1; then
    echo "zip command not found. Please install zip and rerun make_zip.sh inside ${ROOT_DIR}."
    exit 0
  fi
  zip -r "../${ZIPNAME}" . >/dev/null
)
echo "Generated ${ROOT_DIR} and zip ${ZIPNAME}"
echo "Run: cd ${ROOT_DIR} && git init && git checkout -b inzo/init-inzo-tools && git add . && git commit -m \"chore: add scaffold\" && git remote add origin <your-remote> && git push -u -f origin inzo/init-inzo-tools:main"