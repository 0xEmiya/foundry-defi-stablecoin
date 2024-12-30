# Defi Stablecoin 项目

这是一个去中心化稳定币(DSC - Decentralized Stablecoin)项目,跟随 Cyfrin 的 Solidity 全栈课程开发。

## 项目特点

- 锚定 1 美元
- 算法稳定
- 超额抵押
- 可以使用外部喂价
- 以 WETH 和 WBTC 作为抵押品

## 开发工具

本项目使用 Foundry 开发。Foundry 是一个用 Rust 编写的快速、便携和模块化的以太坊应用开发工具包。

主要组件:

- **Forge**: 以太坊测试框架 (类似 Truffle, Hardhat 和 DappTools)
- **Cast**: 用于与 EVM 智能合约交互的多功能工具
- **Anvil**: 本地以太坊节点 (类似 Ganache, Hardhat Network)
- **Chisel**: 快速、实用的 Solidity REPL

## 使用说明

### 构建

```shell
$ forge build
```

### 测试

```shell
$ forge test
```

### 代码格式化

```shell
$ forge fmt
```

### Gas 快照

```shell
$ forge snapshot
```

### 本地节点

```shell
$ anvil
```

### 部署

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast 工具

```shell
$ cast <subcommand>
```

## 相关文档

- Foundry 文档: https://book.getfoundry.sh/

## 帮助

```shell
$ forge --help
$ anvil --help
$ cast --help
```
