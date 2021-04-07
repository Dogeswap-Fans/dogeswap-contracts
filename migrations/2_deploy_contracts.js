const ConvertLib = artifacts.require("ConvertLib");

module.exports = function(deployer) {
  deployer.deploy(ConvertLib);
};
