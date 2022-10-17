// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";


contract Voting is Ownable {

    /**
     * Structs & Enums
    **/
    struct Voter {
        bool isRegistered;
        
        /**
         * Replaces 'bool hasVoted'
         * In order to handle ties - for which the voting session is re-openned.
        **/ 
        uint votesNb;
        uint votedProposalId;

        /**
         * Added to handle bribes (i.e. a Voter buying the vote of an another Voter)
         * Any value different from 0 indicates that the Voter is willing to sell her vote at the price of {bribe} Wei
         * The bribe can be defined in {ProposalsRegistrationStarted} phase using the {defineBribe()} function.
         * The bribe can be sent in {VotingSessionStarted} phase using the {bribe()} function. 
         * A Voter cannot be brided if she has already voted. Once bribed, the Voter cannot vote anymore. 
        **/
        uint bribe; 
    }

    struct Proposal {
        string description;
        uint voteCount;
    }

    enum WorkflowStatus {
        RegisteringVoters,
        ProposalsRegistrationStarted,
        ProposalsRegistrationEnded,
        VotingSessionStarted,
        VotingSessionEnded,
        VotesTallied
    }

    /**
     * State variables
    **/
    WorkflowStatus private _status;
    uint private _winningProposalId;
    uint private _totalVotesCount;
    mapping (address => Voter) private _voters;
    Proposal[] private _proposals;
    bool private _isAtLeastOneVoter;

    /**
     * To handle ties.
     * 
     * If there are many more Voters than Proposals, ties are very unlikely to happen.
     * Here ties are handled by starting with a new voting session between the tie Proposals only.
     * Thus, the WorkflowStatus is rewinded to VotingSessionStarted.
    **/
    uint[] private _winningProposalIds;
    uint private _votingSessionsNb;
    Proposal[] private _winningProposals;
    bool private _isWinnerFound;

    /**
     * Events 
    **/
    event VoterRegistered(address voterAddress); 
    event WorkflowStatusChange(WorkflowStatus previousStatus, WorkflowStatus nexStatus);
    event ProposalRegistered(uint proposalId);
    event Voted(address voter, uint proposalId);
    event Tie();

    constructor() Ownable() {
        _status = WorkflowStatus.RegisteringVoters;
        _votingSessionsNb = 1;
    }

    receive() external payable {
    }

    /**
     * Modifiers
     * (Some of them may be overkill for now)
    **/
    modifier onlyRegisteringVoters()  {
        require (_status == WorkflowStatus.RegisteringVoters, "Operation not allowed : vote registering is closed");
        _;
    }

    modifier onlyProposalsRegistrationStarted() {
        require (_status == WorkflowStatus.ProposalsRegistrationStarted, "Operation not allowed : proposals registering has not begun or is closed");
        _;
    }

    modifier onlyVotingSessionStarted() {
        require (_status == WorkflowStatus.VotingSessionStarted, "Operation not allowed : voting session has not begun or is closed");
        _;
    }

    modifier onlyVotesTallied() {
        require (_status == WorkflowStatus.VotesTallied, "Operation not allowed : Votes are not tallied yet");
        _;
    }

    modifier onlyRegisteredVoters() {
        require (_voters[msg.sender].isRegistered, "Operation not allowed : You are not a registered voter");
        _;
    }


    /*
     * During any phase (except {VotesTallied}), allows the owner to switch to the next phase.
     * If the status is {VotingSessionEnded}, the votes are tallied.
     * Then, the status is switched to {VotesTallied}, excepted if they is a tie, in which case, the status is
     * rewinded to VotingSessionStarted, and a new voting session is started with only the ties Proposals.
    **/
    function nextPhase() external onlyOwner {
        require (_status != WorkflowStatus.VotesTallied, "Operation not allowed : vote is already tallied");

        if (_status == WorkflowStatus.RegisteringVoters) {
            require (_isAtLeastOneVoter, "There are no voters !");
            _status = WorkflowStatus.ProposalsRegistrationStarted;
            emit WorkflowStatusChange(WorkflowStatus.RegisteringVoters, _status);
        }
        else if (_status == WorkflowStatus.ProposalsRegistrationStarted) {
            require (_proposals.length != 0, "There are no proposals !");
            _status = WorkflowStatus.ProposalsRegistrationEnded;
            emit WorkflowStatusChange(WorkflowStatus.ProposalsRegistrationStarted, _status);
        }
        else if (_status == WorkflowStatus.ProposalsRegistrationEnded) {
            _status = WorkflowStatus.VotingSessionStarted;
            emit WorkflowStatusChange(WorkflowStatus.ProposalsRegistrationEnded, _status);
        }
        else if (_status == WorkflowStatus.VotingSessionStarted) {
            _status = WorkflowStatus.VotingSessionEnded;
            emit WorkflowStatusChange(WorkflowStatus.VotingSessionStarted, _status);
        }
        else if (_status == WorkflowStatus.VotingSessionEnded) {
            _tallyHandleTie();
            if (_isWinnerFound) { 
                _status = WorkflowStatus.VotesTallied;
                emit WorkflowStatusChange(WorkflowStatus.VotingSessionEnded, _status);
            }
            else { // Rewind the status to start a new Voting session 
                _status = WorkflowStatus.VotingSessionStarted;
                emit WorkflowStatusChange(WorkflowStatus.VotingSessionEnded, _status);
                emit Tie();
            }
        }
    }

    /**
     * During the {RegisteringVoters} phase, allows the Owner to register a Voter.
    **/
    function registerVoter(address _addr) external onlyOwner onlyRegisteringVoters {
        require (_addr != address(0), "You cannot register the null address");

        _voters[_addr] = Voter(true, 0, 0, 0);
        if (!_isAtLeastOneVoter)
            _isAtLeastOneVoter = true;

        emit VoterRegistered(_addr);
    }

    /**
     * During the {ProposalsRegistrationStarted} phase, allows a registered Voter to register a Proposal.
    **/
    function registerProposal(string calldata _description) external onlyProposalsRegistrationStarted onlyRegisteredVoters {
        require (bytes(_description).length != 0, "Please add the description of your proposal");

        uint _id = _proposals.length; 
        _proposals.push(Proposal(_description, 0)); 

        emit ProposalRegistered(_id);
    }

    /**
     * During the {ProposalsRegistrationStarted} phase, allows a registered Voter to sets the minimum 
     * bribe value that she requests to sell her vote.
    **/
    function defineBribe(uint _value) external onlyProposalsRegistrationStarted onlyRegisteredVoters {
        _voters[msg.sender].bribe = _value;
    }

    /**
     * During the {VotingSessionStarted} phase, allows a registered Voter to vote for any registered Proposal.
     * Proposals are identified by a unique _id.
     * The details of the Proposals can be requested using the {getProposalsDetails()} function. 
    **/
    function vote(uint _id) external onlyVotingSessionStarted onlyRegisteredVoters {
        require (_voters[msg.sender].votesNb < _votingSessionsNb, "You can only vote once");
        require (_id < _proposals.length, "The id does not match to any proposal");

        _proposals[_id].voteCount++;
        _voters[msg.sender].votesNb++;
        _voters[msg.sender].votedProposalId = _id;

        emit Voted(msg.sender, _id);
    }

    /**
     * During the {VotingSessionStarted} phase, allows a registered Voter to send a bribe 
     * to another registered Voter.
    **/
    function bribe(address _addr, uint _id) external payable onlyVotingSessionStarted onlyRegisteredVoters {
        require (_voters[_addr].bribe != 0, "You cannot bribe this address");
        require (_voters[_addr].votesNb < _votingSessionsNb, "You can only bribe an address which has not voted yet");
        require (_voters[_addr].bribe <= msg.value, "Your bribe is not enough");
        require (_id < _proposals.length, "The id does not match to any proposal");

        (bool success, ) = _addr.call{value:msg.value, gas: 25000}("");
        require (success, "Bribe failed !");

        _proposals[_id].voteCount++;
        _voters[_addr].votesNb++;
        _voters[_addr].votedProposalId = _id;

        emit Voted(_addr, _id);
    }

    /**
     * Deprecated - Old function to tally the votes. Does not handle ties. Replaced by _tallyHandleTie().
     * Also counts the total number of votes and stores it in {_totalVotesCount}.
    **/
    function _tally() internal {
        uint _maxCount = 0;
        _totalVotesCount = 0;

        for (uint _id=0; _id<_proposals.length; _id++) {
            if (_proposals[_id].voteCount > _maxCount) {
                _winningProposalId = _id;
                _maxCount = _proposals[_id].voteCount;
            }
            _totalVotesCount += _proposals[_id].voteCount;
        }
    }

    /**
     * Latest function to tally the votes, this time handling ties. Replaces _tally().
     * Also counts the total number of votes and stores it in {_totalVotesCount}.
    **/
    function _tallyHandleTie() internal {
        uint _maxCount = 0;
        _totalVotesCount = 0;

        // Finds the Proposal(s) with the greatest vote count, and stores them and their _ids in _winningProposals and _winningProposalIds
        for (uint _id=0; _id<_proposals.length; _id++) {
            if (_proposals[_id].voteCount >= _maxCount) {
                // If the winning proposals have less votes than the currently watched proposal, remove them from the winning list 
                if (_proposals[_id].voteCount > _maxCount) {
                    while (_winningProposalIds.length != 0)
                        _winningProposalIds.pop();
                    while (_winningProposals.length != 0)
                        _winningProposals.pop();
                }
                _winningProposalIds.push(_id);
                _winningProposals.push(_proposals[_id]);
                _maxCount = _proposals[_id].voteCount;
            }
            _totalVotesCount += _proposals[_id].voteCount;
        }

        if (_winningProposalIds.length == 1) { 
            // There is no Tie, we set the Winner.
            _winningProposalId = _winningProposalIds[0];
            _isWinnerFound = true;
        }
        else { 
            // There is a Tie, the list of Proposals is replaced by the list of the winning Proposals.
            while (_proposals.length != 0)
                _proposals.pop();
            uint _winningProposalsNb = _winningProposals.length;
            while (_proposals.length != _winningProposalsNb) {
                _proposals.push(_winningProposals[_winningProposals.length - 1]);
                _proposals[_proposals.length - 1].voteCount = 0;
                _winningProposals.pop();
            }
            _votingSessionsNb ++;
        }

    }

    /**
     * During any phase, allows anybody to see current phase.
    **/
    function getStatus() external view returns(string memory) {
        string memory str;
        if (_status == WorkflowStatus.RegisteringVoters) {
            str = "RegisteringVoters";
        }
        else if (_status == WorkflowStatus.ProposalsRegistrationStarted) {
            str = "ProposalsRegistrationStarted";
        }
        else if (_status == WorkflowStatus.ProposalsRegistrationEnded) {
            str = "ProposalsRegistrationEnded";
        }
        else if (_status == WorkflowStatus.VotingSessionStarted) {
            str = "VotingSessionStarted";
        }
        else if (_status == WorkflowStatus.VotingSessionEnded) {
            str = "VotingSessionEnded";
        }
        else if (_status == WorkflowStatus.VotesTallied) {
            str = "VotesTallied";
        }
        return str;
    }

    /**
     * During the {VotingSessionStarted} phase and after, allows a registered Voter to see the vote  
     * of another registered Voter, giving only her adress.
    **/
    function getVote(address _addr) external view onlyRegisteredVoters returns(uint)
    {
        require (_voters[_addr].votesNb >= _votingSessionsNb, "The address given has not voted.");
        return _voters[_addr].votedProposalId;
    }

    /**
     * During the {VotesTallied} phase, allows anybody to get the winning Proposal id.
    **/
    function getWinner() external view onlyVotesTallied returns(uint) {
        return _winningProposalId;
    }

    /**
     * During the {VotesTallied} phase, allows anybody to see the results of the vote.
    **/
    function getWinnerDetails() external view onlyVotesTallied returns(string memory) {

        string memory str1 = " The winner is the following proposal: \n";
        string memory str2 = _proposals[_winningProposalId].description;
        string memory str3 = " \nProposal id: ";
        string memory str4 = Strings.toString(_winningProposalId);
        string memory str5 = " \nNumbers of votes for this proposal: ";
        string memory str6 = Strings.toString(_proposals[_winningProposalId].voteCount);
        string memory str7 = " \nTotal number of votes: ";
        string memory str8 = Strings.toString(_totalVotesCount);

        string memory str = string(bytes.concat(bytes(str1), bytes(str2), bytes(str3), bytes(str4), bytes(str5), bytes(str6), bytes(str7), bytes(str8)));
        return str;
    }

    /**
     * During the {VotingSessionStarted} phase, allows anybody to see the details of each Proposal.
    **/
    function getProposalsDetails() external view onlyVotingSessionStarted returns(string memory) {
        string memory str = "";
        string memory str1 = "";
        string memory str2 = "";
        string memory str3 = "";
        string memory str4 = "";
        string memory str5 = "";
        string memory str6 = "";
        for (uint _id=0; _id<_proposals.length; _id++) {
            str1 = " Id: \n";
            str2 = Strings.toString(_id);
            str3 = " \nDescription: \n";
            str4 = _proposals[_id].description;
            str5 = " \nNumbers of votes: ";
            str6 = Strings.toString(_proposals[_id].voteCount);
            str = string(bytes.concat(bytes(str), bytes(str1), bytes(str2), bytes(str3), bytes(str4), bytes(str5), bytes(str6)));
        }
        return str;
    }

}
