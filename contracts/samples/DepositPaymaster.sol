// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

/* solhint-disable reason-string */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../core/BasePaymaster.sol";
import "./Oracle.sol";

/**
 * A token-based paymaster that accepts token deposits
 * The deposit is only a safeguard: the user pays with his token balance.
 *  only if the user didn't approve() the paymaster, or if the token balance is not enough, the deposit will be used.
 *  thus the required deposit is to cover just one method call.
 * The deposit is locked for the current block: the user must issue unlockTokenDeposit() to be allowed to withdraw
 *  (but can't use the deposit for this or further operations)
 *
 * paymasterAndData holds the paymaster address followed by the token address to use.
 * @notice This paymaster will be rejected by the standard rules of EIP4337, as it uses an external oracle.
 * (the standard rules ban accessing data of an external contract)
 * It can only be used if it is "whitelisted" by the bundler.
 * (technically, it can be used by an "oracle" which returns a static value, without accessing any storage)
 */
contract DepositPaymaster is BasePaymaster {

    using UserOperationLib for UserOperation;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    //calculated cost of the postOp
    uint256 constant public COST_OF_POST = 35000;

    IOracle private constant NULL_ORACLE = IOracle(address(0));
    mapping(IERC20 => IOracle) public oracles;
    mapping(IERC20 => mapping(address => uint256)) public balances;

    constructor(IEntryPoint _entryPoint) BasePaymaster(_entryPoint) {}

    function addToken(IERC20 token, address base, address quote) public {
        require(oracles[token] == NULL_ORACLE, "Token already set");
        oracles[token] = new Oracle(base, quote, 8);
    }

    function addDepositFor(IERC20 token, address account, uint256 amount) external {
        require(oracles[token] != NULL_ORACLE, "unsupported token");
        balances[token][account] += amount;
    }
    function depositInfo(IERC20 token, address account) public view returns (uint256 amount) {
        amount = balances[token][account];
    }

    function withdrawTokensTo(IERC20 token, address target, uint256 amount) public {
        require(unlockBlock[msg.sender] != 0 && block.number > unlockBlock[msg.sender], "DepositPaymaster: must unlockTokenDeposit");
        balances[token][msg.sender] -= amount;
    }

    function getTokenValueOfEth(IERC20 token, uint256 ethBought) public view virtual returns (uint256 requiredTokens) {
        Oracle oracle = oracles[token];
        require(oracle != NULL_ORACLE, "DepositPaymaster: unsupported token");
        uint price = uint(oracle.getLatestPrice());
        requiredTokens = ethBought.mul(price).div(10 ** 18);
    }

    function _validatePaymasterUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
    internal view override returns (bytes memory context, uint256 validationData) {
        (userOpHash);
        require(userOp.verificationGasLimit > COST_OF_POST, "DepositPaymaster: gas too low for postOp");

        bytes calldata paymasterAndData = userOp.paymasterAndData;
        require(paymasterAndData.length == 20+20, "DepositPaymaster: paymasterAndData must specify token");

        IERC20 token = IERC20(address(bytes20(paymasterAndData[20:])));
        address account = userOp.getSender();
        uint256 maxTokenCost = getTokenValueOfEth(token, maxCost);
        uint256 gasPriceUserOp = userOp.gasPrice();

        require(balances[token][account] >= maxTokenCost, "DepositPaymaster: deposit too low");
        return (abi.encode(account, token, gasPriceUserOp, maxTokenCost, maxCost), 0);
    }

    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost) internal override {

        (address account, IERC20 token, uint256 gasPricePostOp, uint256 maxTokenCost, uint256 maxCost) = abi.decode(context, (address, IERC20, uint256, uint256, uint256));
        //use same conversion rate as used for validation.
        uint256 actualTokenCost = (actualGasCost + COST_OF_POST * gasPricePostOp) * maxTokenCost / maxCost;
        if (mode != PostOpMode.postOpReverted) {
            // attempt to pay with tokens:
            token.safeTransferFrom(account, address(this), actualTokenCost);
        } else {
            //in case above transferFrom failed, pay with deposit:
            balances[token][account] -= actualTokenCost;
        }
        balances[token][owner()] += actualTokenCost;
    }
}
