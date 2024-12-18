import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:fstapp/components/dataGrid/DataGridAction.dart';
import 'package:fstapp/dataModels/OccasionUserModel.dart';
import 'package:fstapp/components/dataGrid/SingleTableDataGrid.dart';
import 'package:fstapp/dataModels/Tb.dart';
import 'package:fstapp/dataModels/UserInfoModel.dart';
import 'package:fstapp/dataServices/AuthService.dart';
import 'package:fstapp/dataServices/DbGroups.dart';
import 'package:fstapp/dataServices/DbUsers.dart';
import 'package:fstapp/dataServices/RightsService.dart';
import 'package:fstapp/pages/AdministrationOccasion/ColumnHelper.dart';
import 'package:fstapp/services/DialogHelper.dart';
import 'package:fstapp/services/ToastHelper.dart';
import 'package:fstapp/services/UserManagementHelper.dart';

class UsersTab extends StatefulWidget {
  const UsersTab({super.key});

  @override
  _UsersTabState createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  static const List<String> columnIdentifiers = [
    ColumnHelper.ID,
    ColumnHelper.EMAIL,
    ColumnHelper.NAME,
    ColumnHelper.SURNAME,
    ColumnHelper.SEX,
    ColumnHelper.ACCOMMODATION,
    ColumnHelper.PHONE,
    ColumnHelper.BIRTHDAY,
    ColumnHelper.ROLE,
    ColumnHelper.ADMINISTRATOR,
    ColumnHelper.EDITOR,
    ColumnHelper.APPROVER,
    ColumnHelper.APPROVED,
    ColumnHelper.INVITED
  ];

  List<UserInfoModel>? _allUsers; // Initialize as null to indicate loading state
  Key refreshKey = UniqueKey(); // Initialize the refresh key

  @override
  void initState() {
    super.initState();
    loadUsers();
  }

  Future<void> loadUsers() async {
    _allUsers = await DbUsers.getAllUsersBasics();
    setState(() {
      refreshKey = UniqueKey(); // Update the key to force a full rebuild
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_allUsers == null) {
      return Center(child: CircularProgressIndicator()); // Show loading indicator if users are not loaded yet
    }

    return KeyedSubtree(
      key: refreshKey,
      child: SingleTableDataGrid<OccasionUserModel>(
        context,
        DbUsers.getOccasionUsers,
        OccasionUserModel.fromPlutoJson,
        DataGridFirstColumn.deleteAndCheck,
        Tb.occasion_users.user,
        actionsExtended: DataGridActionsController(
            areAllActionsEnabled: RightsService.canUpdateUsers),
        headerChildren: [
          DataGridAction(name: "Import".tr(), action: (SingleTableDataGrid p0, [_]) => _import(p0)),
          DataGridAction(name: "Add existing".tr(), action: (SingleTableDataGrid p0, [_]) => _addExisting(p0)),
          DataGridAction(name: "Invite".tr(), action: (SingleTableDataGrid p0, [_]) => _invite(p0)),
          DataGridAction(name: "Change password".tr(), action: (SingleTableDataGrid p0, [_]) => _setPassword(p0)),
          DataGridAction(name: "Add to group".tr(), action: (SingleTableDataGrid p0, [_]) => _addToGroup(p0)),
        ],
        columns: ColumnHelper.generateColumns(columnIdentifiers),
      ).DataGrid(),
    );
  }

  // Actions (import, invite, change password, add to group, add existing)
  Future<void> _import(SingleTableDataGrid dataGrid) async {
    await UserManagementHelper.import(context);
    await loadUsers(); // Reload users and force rebuild
  }

  Future<void> _setPassword(SingleTableDataGrid dataGrid) async {
    var users = _getCheckedUsers(dataGrid);
    if (users.isEmpty) return;
    for (var u in users) {
      await UserManagementHelper.unsafeChangeUserPassword(context, u);
    }
    ToastHelper.Show(context, "Password has been changed.".tr());
  }

  Future<void> _addToGroup(SingleTableDataGrid dataGrid) async {
    var users = _getCheckedUsers(dataGrid);
    var chosenGroup = await DialogHelper.showAddToGroupDialogAsync(context, await DbGroups.getAllUserGroupInfo());
    if (chosenGroup != null) {
      chosenGroup.participants!.addAll(users.map((u) => UserInfoModel(id: u.user)));
      await DbGroups.updateUserGroupParticipants(chosenGroup, chosenGroup.participants!);
      ToastHelper.Show(context, "Updated {item}.".tr(namedArgs: {"item": chosenGroup.title}));
    }
  }

  Future<void> _addExisting(SingleTableDataGrid dataGrid) async {
    if (_allUsers == null) return;
    var nonAdded = _allUsers!.where((u) => !_getCheckedUsers(dataGrid).any((cu) => cu.user == u.id)).toList();
    DialogHelper.chooseUser(context, (chosenUser) async {
      if (chosenUser != null) {
        await DbUsers.addUserToOccasion(chosenUser.id, RightsService.currentOccasion!);
        ToastHelper.Show(context, "Updated {item}.".tr(namedArgs: {"item": chosenUser.toString()}));
        await loadUsers(); // Reload users and force rebuild
      }
    }, nonAdded, "Add".tr());
  }

  List<OccasionUserModel> _getCheckedUsers(SingleTableDataGrid dataGrid) {
    return List<OccasionUserModel>.from(
      dataGrid.stateManager.refRows.originalList
          .where((row) => row.checked == true)
          .map((row) => OccasionUserModel.fromPlutoJson(row.toJson())),
    );
  }

  Future<void> _invite(SingleTableDataGrid dataGrid) async {
    var users = _getCheckedUsers(dataGrid);
    if (users.isEmpty) return;

    // Separate already invited users
    var alreadyInvitedUsers = users.where((user) => user.data![Tb.occasion_users.data_isInvited] == true).toList();
    var newUsers = users.where((user) => user.data![Tb.occasion_users.data_isInvited] != true).toList();

    if (alreadyInvitedUsers.isNotEmpty) {
      // Ask the user if they want to reinvite already invited users
      var reinviteConfirm = await DialogHelper.showConfirmationDialogAsync(
        context,
        "Invite".tr(),
        "Some users have already been invited. Do you want to invite them again and send a new sign-in code?".tr(),
      );

      // If the user chooses not to reinvite, exclude already invited users
      if (!reinviteConfirm) {
        await _processInvites(newUsers, dataGrid);
        return;
      }
    }

    // Proceed with inviting both new and previously invited users (if reinvite confirmed)
    await _processInvites(users, dataGrid);
  }

  Future<void> _processInvites(List<OccasionUserModel> users, SingleTableDataGrid dataGrid) async {
    var confirm = await DialogHelper.showConfirmationDialogAsync(
        context,
        "Invite".tr(),
        "${"Users will get a sign-in code via e-mail.".tr()} (${users.length}):\n${users.map((u) => u.toBasicString()).join(",\n")}"
    );

    if (confirm) {
      ValueNotifier<int> invitedCount = ValueNotifier(0);

      // Show progress dialog
      DialogHelper.showProgressDialogAsync(
        context,
        "Invite".tr(),
        users.length,
        invitedCount,
      );

      for (var user in users) {
        // slow down to avoid rate limit SES has 14 email / sec
        await Future.delayed(Duration(milliseconds: 100));
        await AuthService.sendSignInCode(user);
        invitedCount.value++;

        ToastHelper.Show(
          context,
          "Invited: {user}.".tr(namedArgs: {"user": user.data![Tb.occasion_users.data_email]}),
        );
      }

      Navigator.of(context).pop(); // Close the dialog

      await loadUsers(); // Reload users

      await DialogHelper.showInformationDialogAsync(
        context,
        "Invite".tr(),
        "Users ({count}) invited successfully.".tr(namedArgs: {"count": invitedCount.value.toString()}),
      );
    }
  }
}
